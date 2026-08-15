# 内容一键复制与 Quick Look 复制格式实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**目标：** 新增默认开启的“内容一键复制”总开关，并允许用户为 Quick Look 选择复制“富文本”或“原始 Markdown 文本”；三个内容区入口遵循同一开关且保持各自既有复制语义。

**架构：** 将跨主应用和 Quick Look Extension 使用的偏好 key、Quick Look 格式、默认值及 Web 页面复制配置收敛到 MarkdownReaderKit。主应用 SettingsModel 只持久化/绑定设置；阅读 WebView 通过既有 JavaScript bridge 无重载地增删按钮，Raw 编辑器直接由 SwiftUI 状态控制。Quick Look 每次 preparePreviewOfFile 时从主应用 CFPreferences 域取设置快照，并复用 Kit 中的 SF Symbol 图标提供者、HTML、JavaScript 和 CSS 合同。

**技术栈：** Swift 6.2、SwiftUI Observation、AppKit NSPasteboard、CoreFoundation Preferences、Quick Look UI、WebKit WKWebView、JavaScript DOM Selection、CSS、XCTest、Swift Package Manager。

---

## 一、目标产品合同

### 1. 设置

| 设置位置 | 控件 | 默认 | 作用 |
|---|---|---:|---|
| 通用设置 | 内容一键复制 Toggle | 开启 | 控制主阅读、Raw 编辑、Quick Look 的“整篇内容复制”按钮 |
| 通用设置 > Quick Look 预览 | 一键复制内容：富文本 / 原始 Markdown 文本 | 富文本 | 仅决定 Quick Look 的整篇内容复制格式 |

- 关闭“内容一键复制”时，三处整篇内容复制按钮都不显示；重新打开后主应用当前页面立即恢复，不能重载正文、丢失滚动位置、查找状态、编辑焦点或未保存内容。
- Quick Look 设置在下次打开或刷新 Finder 预览时生效；不要求跨进程刷新已打开的 Quick Look 窗口。
- 总开关打开时，在现有“Quick Look 预览”区段里、“启用 Quick Look 预览”Toggle 下方显示格式选择器。Quick Look Preview 自身关闭时，格式选择仍显示并保留已选值。
- 主应用阅读模式继续复制渲染富文本，Raw 模式继续复制当前编辑缓冲区的原始 Markdown。Quick Look 格式设置不得影响主应用两个入口。

### 2. 总开关范围

| 入口 | 总开关打开时的内容 | 关闭时 |
|---|---|---|
| 主应用阅读右上角 | mr-content 的渲染富文本 | 移除 WebKit 文档按钮 |
| 主应用 Raw 编辑右上角 | documentViewModel.content | 不渲染 SwiftUI 按钮 |
| Finder Quick Look 右上角 | 由 Quick Look 格式决定 | 不创建 WebKit 按钮 |

不受本任务影响的既有能力：

- 标题栏、Finder/侧边栏的“复制路径”；
- 代码块悬停复制（仍复制代码文本、两秒反馈）；
- PDF/打印隐藏文档复制按钮；
- Markdown 渲染、查找、主题、布局和 WebView 渲染调度。

### 3. Quick Look 复制语义

- 富文本：保持 MR.copyRenderedContent 的真实点击路径。临时选择 mr-content，执行 document.execCommand("copy")，复制结果等同用户页面全选复制，保留标题、强调、表格、代码等富文本结构。
- 原始 Markdown 文本：复制 preparePreviewOfFile 已读取的 UTF-8 文件原文；不得从 DOM textContent 还原。页面点击时通过临时 textarea + document.execCommand("copy") 写入纯文本。
- 两种格式都只在 copy 返回成功时显示绿色 checkmark 五秒；连续成功点击从最后一次成功重新计时；失败不显示成功反馈。
- 原始 Markdown 不能直接插入 HTML/JavaScript。由 HTML Service 将 UTF-8 Data 编码为 base64 attribute，JavaScript 以 atob + TextDecoder("utf-8") 解码。含引号、标签、换行、中文和 emoji 的内容都必须字节保真且不可执行。

## 二、共享模型、持久化和数据流

~~~mermaid
flowchart LR
  A[GeneralSettingsView] --> B[SettingsModel UserDefaults]
  B --> C[DetailView Raw overlay]
  B --> D[WebViewMarkdownView JavaScript bridge]
  B --> E[CFPreferences main app domain]
  E --> F[MarkdownQLPreviewProvider snapshot]
  F --> G[DocumentCopyPageConfiguration]
  D --> H[markdown-reader.js document button]
  G --> H
~~~

### 1. 新建共享配置模型

新建 Sources/MarkdownReaderKit/Models/DocumentCopyConfiguration.swift，包含无 UI、Sendable、Equatable 的类型：

~~~swift
public enum QuickLookDocumentCopyFormat: String, CaseIterable, Codable, Sendable {
    case richText
    case rawMarkdown
}

public enum SharedPreferenceKey {
    public static let applicationID = "com.markdownreader.app"
    public static let languagePref = "com.markdownreader.languagePref"
    public static let enableQuickLookPreview = "com.markdownreader.enableQuickLookPreview"
    public static let enableDocumentCopy = "com.markdownreader.enableDocumentCopy"
    public static let quickLookDocumentCopyFormat = "com.markdownreader.quickLookDocumentCopyFormat"
}

public struct QuickLookDocumentCopySettings: Equatable, Sendable {
    public let isDocumentCopyEnabled: Bool
    public let format: QuickLookDocumentCopyFormat
    public let language: Language
}

public struct DocumentCopyPageConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let format: QuickLookDocumentCopyFormat
    public let rawMarkdown: String?
    public let copyTitle: String
    public let copiedTitle: String
    public let webIcons: DocumentCopyWebIcons
}
~~~

QuickLookDocumentCopySettings 必须有纯初始化入口，接收已存储的可选 Bool/String 和显式 detectedLanguage，以便单测。缺失/无效值的兼容默认值为：

- 内容一键复制：true；
- Quick Look 格式：richText；
- 语言偏好：LanguageService.detectLanguage()；
- 有效 LanguagePref 的非 auto 值直接映射，auto 仍使用检测语言。

偏好 key、默认值及格式解析仅在此共享文件定义。Quick Look Provider 只能读取原始 CFPreferences 再构造快照，不能复制 key 字符串、默认值或解析逻辑。

### 2. 页面配置合同

DocumentCopyPageConfiguration 生成 HTML 属性和 icons CSS fragment。需满足：

- disabled 配置不输出 data-document-copy-enabled="true"、raw base64 或 icon CSS variables；
- enabled 配置输出 data-document-copy-enabled、data-document-copy-format、已 XML 属性转义的 title/aria 文案；
- 仅 rawMarkdown 格式并有 raw 内容时输出 data-document-copy-raw-base64；
- base64 使用 Data(rawMarkdown.utf8).base64EncodedString()；
- icons 不可用时，按钮创建仍安全 no-op；
- buildFullHTML 与 buildContentAwareHTML 使用同一个配置，不再各自持有散落的 documentCopyTitle、documentCopiedTitle、documentCopyWebIcons 参数；
- 默认配置为 disabled，保护 PDF 导出和未迁移入口不出现按钮。

HTML 示例：

~~~html
<div class="markdown-preview"
     data-document-copy-enabled="true"
     data-document-copy-format="rawMarkdown"
     data-document-copy-raw-base64="..."
     data-document-copy-title="Copy Content"
     data-document-copied-title="Content Copied">
~~~

### 3. SettingsModel

SettingsModel 新增：

~~~swift
var enableDocumentCopy: Bool
var quickLookDocumentCopyFormat: QuickLookDocumentCopyFormat
~~~

- didSet 分别持久化 Bool 和 rawValue；
- 初始化仅在新 key 缺失时写入 true 与 richText.rawValue，绝不覆盖已有用户值；
- 现有 languagePref、enableQuickLookPreview 改为使用 SharedPreferenceKey 中的 key，其他无关 key 继续私有；
- 维持 enableQuickLookPreview 的既有 default-on 行为；
- GeneralSettingsView 在 Quick Look 区段之前加“内容一键复制”区段。Quick Look 区段保留原 Toggle；当 enableDocumentCopy 为 true 时在其下显示格式 Picker。

本地化新增键和值：

| Key | English | 简体中文 | 繁體中文 |
|---|---|---|---|
| settingsGeneralContentCopyTitle | Content Copy | 内容一键复制 | 內容一鍵複製 |
| settingsGeneralContentCopyEnabled | Enable one-click content copy | 启用一键复制 | 啟用一鍵複製 |
| settingsGeneralQuickLookCopyFormat | One-click copy content | 一键复制内容 | 一鍵複製內容 |
| quickLookCopyFormatRichText | Rich Text | 富文本 | 富文字 |
| quickLookCopyFormatRawMarkdown | Raw Markdown Text | 原始 Markdown 文本 | 原始 Markdown 文字 |

所有用户文本都走 L10n.tr；不得在 SettingsView 或 Quick Look Provider 写硬编码文案。

### 4. 主应用即时反映开关

DetailView 的 Raw 复制 overlay 条件新增 settings.enableDocumentCopy，并在该设置变化时调用既有 invalidateCopyFeedback()，取消五秒任务、清除对号，避免关闭再开启后复活旧状态。

WebViewMarkdownView：

- 新增 documentCopyEnabled: Bool 入参，由 DetailView 传入 settings.enableDocumentCopy；
- 首次完整加载传 DocumentCopyPageConfiguration(isEnabled: documentCopyEnabled, format: .richText, rawMarkdown: nil, ...)，但不因初始关闭而省略 icons CSS，保证稍后可无重载恢复；
- 新增 onChange(of: documentCopyEnabled)，调用 MR.setDocumentCopyButtonEnabled(enabled) 后调用既有 syncDocumentCopyButtonVisibility()；
- 此变更不得调用 requestRender、page.load、MR.replaceContent，也不得改变 WebViewRenderScheduler 或 WebViewRenderSnapshot。

markdown-reader.js 新增/调整：

~~~javascript
setDocumentCopyButtonEnabled(enabled) {
  const btn = document.getElementById('mr-document-copy-btn');
  if (!enabled) {
    if (MR._documentCopyTimer) clearTimeout(MR._documentCopyTimer);
    MR._documentCopyTimer = null;
    btn?.remove();
    return;
  }
  MR.addDocumentCopyButton();
}
~~~

真实实现还应同步 preview dataset，但需要满足：

- addDocumentCopyButton 只有 data-document-copy-enabled 是 true 且两项 mask 变量可用时才创建；
- 关闭后没有按钮、hit target、定时器或成功态残留；
- 重开只创建一个按钮；
- 查找栏打开时，恢复按钮仍为 hidden；
- 不改 MR.copyRenderedContent 的 Range 保存/恢复、代码块复制或五秒成功条件。

### 5. Quick Look Provider

MarkdownQLPreviewProvider 保留现有功能：启用 Quick Look guard、security-scoped access、内联图片、Mermaid/KaTeX 内容感知加载、navigation timeout。

读取文件后、HTML 生成前：

1. 用 CFPreferencesCopyAppValue 从 SharedPreferenceKey.applicationID 域读取 languagePref、enableQuickLookPreview、enableDocumentCopy 和 quickLookDocumentCopyFormat；
2. Provider 仅作 Bool/NSNumber、String 的类型桥接，其他值作缺失值；
3. 通过 QuickLookDocumentCopySettings 解析快照，再用 L10n 获取 copy/copy succeeded 标签；
4. 创建 DocumentCopyPageConfiguration；仅 rawMarkdown 格式传当前读取的 content；
5. 将配置传给 buildContentAwareHTML。总开关关闭时仍正常渲染预览，只是不创建整篇内容复制按钮。

将 Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift 以 git mv 移到 Sources/MarkdownReaderKit/Services/SFSymbolWebImageProvider.swift：

- 现有 @MainActor、缓存、注入式 rasterizer seam、14 pt canvas、11 pt Regular symbol 和测试原样保留；
- QL target 已依赖 Kit，build-app.sh 已链接 Kit objects 与 AppKit，无需复制 SVG/PNG 资源或增加 QL 专用图标实现；
- preparePreviewOfFile 若在后台线程，须在 security-scoped access 仍有效时借 DispatchQueue.main.sync + MainActor.assumeIsolated 取得图标；若当前已在主线程则直接取得。不能在后台线程调用 AppKit，也不能把 HTML 构建延后到 access 释放后。

## 三、实施任务

### Task 1：锁定共享偏好和页面配置的测试合同

**Files:**

- Create: Sources/MarkdownReaderKit/Models/DocumentCopyConfiguration.swift
- Create: Tests/MarkdownReaderTests/QuickLookDocumentCopySettingsTests.swift
- Modify: Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift:50-139
- Modify: Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift
- Modify: Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift

**Step 1：先写 Quick Look 快照失败测试**

~~~swift
func testMissingStoredValuesKeepExistingUsersOnRichTextCopy() {
    let settings = QuickLookDocumentCopySettings(
        storedDocumentCopyEnabled: nil,
        storedFormatRawValue: nil,
        storedLanguagePrefRawValue: nil,
        detectedLanguage: .en
    )

    XCTAssertTrue(settings.isDocumentCopyEnabled)
    XCTAssertEqual(settings.format, .richText)
    XCTAssertEqual(settings.language, .en)
}

func testUnknownFormatFallsBackToRichText() {
    let settings = QuickLookDocumentCopySettings(
        storedDocumentCopyEnabled: false,
        storedFormatRawValue: "invalid",
        storedLanguagePrefRawValue: LanguagePref.zhCN.rawValue,
        detectedLanguage: .en
    )

    XCTAssertFalse(settings.isDocumentCopyEnabled)
    XCTAssertEqual(settings.format, .richText)
    XCTAssertEqual(settings.language, .zhCN)
}
~~~

再覆盖 rawMarkdown 和 auto 语言偏好。测试必须显式传 detectedLanguage，不能依赖当前机器 Locale。

**Step 2：写页面壳失败测试**

新增断言：

- disabled 默认配置不会产生 enabled attribute、raw payload 或 mask variables；
- 可用 icons 的 richText 配置会产生 enabled、richText、mask variables 与转义标签；
- raw 内容生成正确 UTF-8 base64，页面 HTML 不直接出现危险原文；
- buildFullHTML 与 buildContentAwareHTML 都遵守同一合同；
- PDF 便利入口默认不出现 document-copy 属性/按钮。

**Step 3：运行并确认失败**

Run:

~~~bash
swift test --filter QuickLookDocumentCopySettingsTests
swift test --filter DocumentCopyWebIconsTests
swift test --filter MarkdownHTMLServiceTests
~~~

Expected：新增类型/参数缺失导致编译失败。

**Step 4：实现最小共享模型和 HTML 配置**

按第二节实现类型、兼容默认值、base64/attribute 生成和两个 HTML 入口的配置参数；CSS、基础脚本顺序、Quick Look Mermaid/KaTeX 条件加载必须不变。

**Step 5：运行验证**

Run:

~~~bash
swift test --filter QuickLookDocumentCopySettingsTests
swift test --filter DocumentCopyWebIconsTests
swift test --filter MarkdownHTMLServiceTests
swift build
~~~

Expected：全部 PASS。

**Step 6：提交**

~~~bash
git add Sources/MarkdownReaderKit/Models/DocumentCopyConfiguration.swift Sources/MarkdownReaderKit/Services/MarkdownHTMLService.swift Tests/MarkdownReaderTests/QuickLookDocumentCopySettingsTests.swift Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift Tests/MarkdownReaderTests/MarkdownHTMLServiceTests.swift
git commit -m "feat: share document copy configuration"
~~~

### Task 2：实现总开关、Quick Look 格式设置和本地化

**Files:**

- Modify: Sources/MarkdownReader/Models/SettingsModel.swift:44-128,364-384
- Modify: Sources/MarkdownReader/Views/SettingsView.swift:132-149
- Modify: Sources/MarkdownReaderKit/Services/LocalizationService.swift:20-65,310-315,506-511,702-707

**Step 1：补齐五个本地化 key**

使用第二节表格的三语文本，键放在相关 General / Quick Look 设置键附近。

**Step 2：持久化两个新设置**

实现 SettingsModel 新属性和默认写入；key 只引用 SharedPreferenceKey。不要在初始化时无条件 set 默认值。

**Step 3：实现设置控件**

在“内容一键复制”Section 放 Toggle；在 Quick Look Section 的启用 Toggle 后有条件地放 Picker：

~~~swift
if settings.enableDocumentCopy {
    Picker(
        L10n.tr(.settingsGeneralQuickLookCopyFormat, language: language),
        selection: $settings.quickLookDocumentCopyFormat
    ) {
        Text(L10n.tr(.quickLookCopyFormatRichText, language: language))
            .tag(QuickLookDocumentCopyFormat.richText)
        Text(L10n.tr(.quickLookCopyFormatRawMarkdown, language: language))
            .tag(QuickLookDocumentCopyFormat.rawMarkdown)
    }
    .pickerStyle(.segmented)
    .frame(width: 260)
}
~~~

**Step 4：构建与手动验收**

Run:

~~~bash
swift build
~~~

Expected：PASS。Debug App 中验证：缺失新 key 时默认值正确；关闭总开关时格式 Picker 隐藏，重开后原格式保留；三种应用语言没有显示 raw key。

**Step 5：提交**

~~~bash
git add Sources/MarkdownReader/Models/SettingsModel.swift Sources/MarkdownReader/Views/SettingsView.swift Sources/MarkdownReaderKit/Services/LocalizationService.swift
git commit -m "feat: add content copy preferences"
~~~

### Task 3：让主应用两处内容复制即时遵从总开关

**Files:**

- Modify: Sources/MarkdownReader/Views/DetailView.swift:638-670,684-720
- Modify: Sources/MarkdownReader/Views/WebViewMarkdownView.swift:80-145,295-324,414-428
- Modify: Sources/MarkdownReader/Resources/js/markdown-reader.js:470-590,710-722
- Verify: Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift

**Step 1：冻结反馈状态测试**

Run:

~~~bash
swift test --filter CopyFeedbackStateTests
~~~

Expected：PASS。若为“关闭立即清除旧对号”新增纯状态路径，增加以下断言后应先失败再实现：

~~~swift
func testInvalidateHidesSuccessBeforeAReenabledControlCanAppear() {
    var state = CopyFeedbackState()
    _ = state.begin()
    state.invalidate()
    XCTAssertFalse(state.isShowingSuccess)
}
~~~

**Step 2：门控 Raw 编辑器按钮**

在 DetailView raw overlay 显示条件加入 settings.enableDocumentCopy；设置变化时调用 invalidateCopyFeedback()。不能修改 copyRawContent、NSPasteboard 成功判断、per-file undo、查找栏或五秒计时。

**Step 3：增加阅读 WebView 的无重载 bridge**

DetailView 传 documentCopyEnabled。WebViewMarkdownView 首次载入传 richText DocumentCopyPageConfiguration，新增 onChange 调用 MR.setDocumentCopyButtonEnabled 并同步查找栏。不得触发 requestRender/page.load/MR.replaceContent。

**Step 4：实现 JavaScript 按钮生命周期**

实现第二节 JavaScript API，并保持富文本 copy 的原选择恢复。关闭需 remove 按钮/clear timer，开启需幂等创建；没有 icons 时 no-op。

**Step 5：自动与真实应用验收**

Run:

~~~bash
swift test --filter CopyFeedbackStateTests
swift build
git diff --check
~~~

Expected：PASS，diff check 无输出。

在浅/深主题验证：

1. 开启时阅读复制富文本、Raw 复制原始文本，均成功对号五秒；
2. 对号期间关闭开关，按钮立即消失；重新开启显示普通 copy，不复活对号；
3. 开关不改变阅读滚动、查找高亮、编辑焦点或未保存内容；
4. 查找栏打开时阅读按钮仍隐藏；
5. 代码块复制和路径复制不受影响。

**Step 6：提交**

~~~bash
git add Sources/MarkdownReader/Views/DetailView.swift Sources/MarkdownReader/Views/WebViewMarkdownView.swift Sources/MarkdownReader/Resources/js/markdown-reader.js Tests/MarkdownReaderTests/CopyFeedbackStateTests.swift
git commit -m "feat: gate app document copy controls"
~~~

### Task 4：在 Quick Look 实现两种格式复制并复用图标

**Files:**

- Move: Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift -> Sources/MarkdownReaderKit/Services/SFSymbolWebImageProvider.swift
- Modify: Sources/MarkdownReaderQL/MarkdownQLPreviewProvider.swift:34-126
- Modify: Sources/MarkdownReader/Resources/js/markdown-reader.js:470-590
- Verify: Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift
- Verify: Tests/MarkdownReaderTests/QuickLookDocumentCopySettingsTests.swift
- Verify: build-app.sh:168-302

**Step 1：先移动图标提供者**

使用 git mv，保持 AppKit 栅格化与缓存测试不变。

Run:

~~~bash
swift test --filter SFSymbolWebImageProviderTests
swift build
~~~

Expected：PASS。主 app 与 QL target 都从 Kit 引用唯一 provider。

**Step 2：在 Provider 读取设置快照、构建配置**

保持 enableQuickLookPreview guard，但使用 SharedPreferenceKey。新增仅作类型桥接的 cfPreferenceBool/cfPreferenceString helper，读 CFPreferencesCopyAppValue(key, applicationID)；Provider 不写 default、不用自己的 extension bundle ID。

读取文件后、security scoped access 有效时，根据 snapshot、content、L10n 和 Kit icons 创建配置并传 buildContentAwareHTML。只有 raw 格式传 rawMarkdown: content。

**Step 3：实现 raw Markdown DOM 复制**

保留 copyRenderedContent 原样，新增 UTF-8 decode + textarea copy：

~~~javascript
decodeUTF8Base64(base64) {
  const bytes = Uint8Array.from(atob(base64), char => char.charCodeAt(0));
  return new TextDecoder('utf-8').decode(bytes);
},

copyRawMarkdownContent(base64) {
  if (!base64) return false;
  const textarea = document.createElement('textarea');
  try {
    textarea.value = MR.decodeUTF8Base64(base64);
    document.body.appendChild(textarea);
    textarea.select();
    return document.execCommand('copy');
  } catch (_) {
    return false;
  } finally {
    textarea.remove();
  }
}
~~~

addDocumentCopyButton 按 data-document-copy-format 选择复制路径。payload 缺失、decode/复制失败都不能显示对号。textarea 只用于 raw Markdown，不能替换富文本的 selection 路径。

**Step 4：打包、签名验证**

Run:

~~~bash
swift test --filter SFSymbolWebImageProviderTests
swift test --filter QuickLookDocumentCopySettingsTests
swift test --filter DocumentCopyWebIconsTests
swift build
./build-app.sh --release --sign
codesign --verify --deep --strict --verbose=2 <app-output>/MarkdownReader.app
codesign --verify --deep --strict --verbose=2 <app-output>/MarkdownReader.app/Contents/PlugIns/MarkdownReaderQL.appex
git diff --check
~~~

Expected：所有测试、构建、app/appex 签名验证通过。实现者必须先确定 build-app.sh 实际 output 目录替换 <app-output>，不得跳过 appex 验证。

**Step 5：Finder Quick Look 真实验收**

用包含标题、加粗、表格、代码块、中文/emoji、特殊文本 </div><script> 与相对图片的 Markdown 样本验证：

1. 总开关关闭：Quick Look 正常渲染、没有整篇内容 copy；代码块复制保持。
2. 开启 + 富文本：重新打开/刷新 Quick Look，复制后粘贴到富文本目标，保留标题、强调、表格和代码结构。
3. 开启 + 原始 Markdown 文本：重新打开/刷新 Quick Look，粘贴到纯文本编辑器，内容与文件 UTF-8 原文逐字一致；特殊字符串不会改变页面或执行。
4. 两种格式都验证成功反馈五秒、连续点击重新计时、重开预览不复用旧对号。
5. Quick Look Preview 总开关关闭/重开后，既有禁用语义无回归，复制格式选择保留。

**Step 6：提交**

~~~bash
git add Sources/MarkdownReaderKit/Services/SFSymbolWebImageProvider.swift Sources/MarkdownReader/Services/SFSymbolWebImageProvider.swift Sources/MarkdownReaderQL/MarkdownQLPreviewProvider.swift Sources/MarkdownReader/Resources/js/markdown-reader.js Tests/MarkdownReaderTests/SFSymbolWebImageProviderTests.swift Tests/MarkdownReaderTests/DocumentCopyWebIconsTests.swift
git commit -m "feat: add configurable quick look document copy"
~~~

## 四、最终验收

- 新安装、旧安装缺少新 key、已有设置三种状态下：内容一键复制默认为开启、Quick Look 默认为富文本，且已有用户选择不被覆盖。
- 一个总开关覆盖主阅读、Raw 编辑、Quick Look 的整篇内容复制，代码块/路径复制不受影响。
- 主应用总开关切换无 WebPage 重载、无滚动/查找/焦点/未保存内容丢失，旧成功态不会复活。
- 每个新 Quick Look 预览从主应用 preference domain 取快照；两种格式的内容语义、UTF-8 保真与五秒反馈符合合同。
- Quick Look 和主阅读页共享 doc.on.doc/checkmark 的 SF Symbol mask 提供者，没有 QL 专用 SVG/PNG 或重复实现。
- swift test、swift build、release app/appex codesign verify、git diff --check 均通过。

## 五、回滚

- 运行时快速止损：将 enableDocumentCopy 设为 false，三处新增整篇内容按钮隐藏，不影响阅读、编辑、代码块复制、路径复制或 Quick Look 渲染。
- 代码回滚：回退本计划对应 commits；遗留未知 UserDefaults key 无害，旧版会忽略。不要为回滚删除用户 defaults。
- 图标 Provider 移动若造成链接问题，应修复共享 Kit target/link 配置并验证 appex；不得恢复为两套 icon 实现。

## 六、不包含

- 不为主阅读或 Raw 编辑增加格式选择；它们保持既有富文本/原始 Markdown 语义。
- 不增加菜单项、快捷键、右键菜单、Toast、权限、网络服务、遥测或剪贴板历史。
- 不跨进程热刷新已打开的 Quick Look，不改 Finder、UTType、security-scoped access、图片内联、Mermaid/KaTeX 超时策略。
- 不改主题、布局、SF Symbol 尺寸、五秒时长、查找逻辑、渲染调度、PDF 导出、版本号或发布流程。
