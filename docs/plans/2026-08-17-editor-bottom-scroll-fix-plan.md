# Markdown Reader 编辑器末尾滚动抖动修复 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在不恢复 v2.3.0 分栏预览的前提下，修复 v2.3.1 Raw 编辑器在文档末尾输入、跳转或语法高亮后出现的插入点不可见与滚动来回跳动。

**Architecture:** 仅在 `SyntaxHighlightedEditor` 的 AppKit 滚动路径恢复 PR #14 中经验证的末行可见性保护：以当前字体的一行高度作为底部留白目标，使用 `clipView.bounds` 作为真实视口，并在高亮恢复前后保证插入点所在行没有被锚点滚动推出视口。将滚动位置的纯几何钳制提取为同文件内的内部 helper，以 XCTest 锁定边界；`NSTextView` 的 line fragment / extra line fragment 继续由 AppKit 实例测试覆盖。

**Tech Stack:** Swift 6.2、SwiftUI `NSViewRepresentable`、AppKit (`NSTextView` / `NSScrollView` / `NSLayoutManager`)、XCTest、Swift Package Manager。

---

## 一、固定范围与根因

| 项目 | 固定值 |
|---|---|
| 实施基线 | `main` / tag `v2.3.1` / `6fc105b` |
| 历史实现参考 | commit `1485185ba996216aae8483f4ddd7b28451349295` 的 `SyntaxHighlightedEditor.swift` 滚动 hunk |
| 修改生产文件 | `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift` |
| 新增测试文件 | `Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift` |

v2.3.1 通过 `3b1edbb` 反转了 v2.3.0 的全部应用代码，故也反转了末尾滚动修复。当前链路为：`textDidChange` 在 50ms 后调用 `reapplyHighlights()` → 保存首个可见字符位置 → 重新高亮和布局 → 按旧锚点恢复 `contentView` 位置 → 恢复 selection。文档末尾新增行或跳转末行时，恢复位置可能把插入点推出视口，随后 AppKit 自动 `scrollRangeToVisible` 再拉回，形成抖动。

本方案恢复 PR #14 的完整滚动保护链，而不是只增大 `textContainerInset`：

1. `HighlightableTextView` 按当前字体维护约一行高度的 `bottomOverscroll`。
2. 正常 `scrollRangeToVisible` 后，仅在文档末行补足下方空白；文末换行时使用 `extraLineFragmentUsedRect`。
3. 跳转行与高亮恢复均使用 `scrollView.contentView.bounds.height`，并把系统管理的 `contentInsets.bottom` 只作为可读取的钳制余量；不得写入任何 scroll/clip view inset。
4. 高亮恢复时，若 selection 所在行不在候选视口内，优先将该行调回可见区，再恢复 selection。

## 二、实施任务

### Task 0：建立隔离工作区并固定回归样本

**Files:**

- Modify: 无。
- Verify: `main`、`v2.3.1`、历史 commit `1485185`。

**Step 1: 保留当前工作区的未提交文件并建立干净 worktree**

当前工作区含用户已有的未跟踪发布回退计划，不能在其中 checkout、stage、restore 或提交。

```bash
git fetch origin main --tags
git status --short --branch
git worktree add -b codex/editor-bottom-scroll-fix \
  ../MarkdownReader-editor-bottom-scroll-fix origin/main
cd ../MarkdownReader-editor-bottom-scroll-fix
git status --short --branch
git describe --exact-match --tags HEAD
```

预期：新 worktree 干净，`HEAD` 为 `v2.3.1`。若 `origin/main` 已前进或无法精确指向该 tag，停止并先审查新增提交；不要把本计划静默套到未知基线。

**Step 2: 记录历史修复与当前缺口**

```bash
git show --format= --unified=12 1485185 -- \
  Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift
git diff --check v2.3.0..v2.3.1 -- \
  Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift
rg -n 'bottomOverscroll|lineFragmentBounds|contentInsets\.bottom|visibleHeight' \
  Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift
```

预期：历史 diff 包含 `bottomOverscroll`、末行 line fragment、`clipView.bounds` 和插入点可见性保护；当前文件不包含 `bottomOverscroll` 或 `lineFragmentBounds`。最后一条命令用于定位现有 `scrollToLineInTextView` 与 `reapplyHighlights`，不是验收替代品。

### Task 1：先建立可失败的滚动几何与 AppKit 回归测试

**Files:**

- Create: `Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift`
- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift:136-208`（仅为测试提供内部几何 helper；Task 2 完成实际接线）。

**Step 1: 写入纯几何的失败测试**

在新测试文件中导入 `XCTest`、`AppKit` 与 `@testable import MarkdownReader`，添加 `@MainActor final class SyntaxHighlightedEditorScrollTests: XCTestCase`。先写入下列测试，测试尚不存在的 `EditorScrollGeometry.restoredOrigin(...)`：

```swift
func testRestoredOriginMovesEndCaretIntoViewportWithBottomOverscroll() {
    let origin = EditorScrollGeometry.restoredOrigin(
        targetY: 900,
        viewportHeight: 100,
        documentHeight: 1_100,
        bottomInset: 8,
        caretTop: 990,
        caretBottom: 1_010,
        bottomOverscroll: 20
    )

    XCTAssertEqual(origin, 930, accuracy: 0.001)
}

func testRestoredOriginDoesNotMoveVisibleInteriorCaret() {
    let origin = EditorScrollGeometry.restoredOrigin(
        targetY: 500,
        viewportHeight: 100,
        documentHeight: 1_100,
        bottomInset: 8,
        caretTop: 530,
        caretBottom: 550,
        bottomOverscroll: 20
    )

    XCTAssertEqual(origin, 500, accuracy: 0.001)
}

func testRestoredOriginClampsAtDocumentBottomIncludingSystemInset() {
    let origin = EditorScrollGeometry.restoredOrigin(
        targetY: 1_050,
        viewportHeight: 100,
        documentHeight: 1_100,
        bottomInset: 8,
        caretTop: 1_095,
        caretBottom: 1_115,
        bottomOverscroll: 20
    )

    XCTAssertEqual(origin, 1_008, accuracy: 0.001)
}
```

**Step 2: 运行新测试，确认它因缺少生产符号而失败**

Run:

```bash
swift test --filter SyntaxHighlightedEditorScrollTests
```

Expected: 编译失败，错误指出 `EditorScrollGeometry` 未定义。不要先实现再补测；该失败证明测试不会意外覆盖旧逻辑。

**Step 3: 添加两个 AppKit 行片段测试**

在同一测试类添加一个只供测试使用的 `makeEditor(text:viewportHeight:)` helper：创建 240pt 宽的 `NSScrollView` 与 `HighlightableTextView`，启用垂直自适应、为 text container 设置无限高度、将 `scrollView.documentView` 设为 text view，并在临时 `NSWindow` 的 contentView 中完成一次 layout。添加：

```swift
func testLineFragmentBoundsUsesExtraFragmentForTrailingNewline() throws {
    let editor = try makeEditor(text: "first\\nlast\\n", viewportHeight: 80)
    let end = NSRange(location: (editor.textView.string as NSString).length, length: 0)

    let rect = try XCTUnwrap(editor.textView.lineFragmentBounds(for: end))

    XCTAssertGreaterThan(rect.height, 0)
    XCTAssertGreaterThanOrEqual(rect.minY, editor.lastGlyphLineBottom)
}

func testScrollRangeToVisibleLeavesOneLineBelowEndCaret() throws {
    let editor = try makeEditor(
        text: String(repeating: "long line for scrolling\\n", count: 120),
        viewportHeight: 80
    )
    let end = NSRange(location: (editor.textView.string as NSString).length, length: 0)
    editor.textView.scrollRangeToVisible(end)

    let caret = try XCTUnwrap(editor.textView.lineFragmentBounds(for: end))
    let caretBottom = caret.maxY + editor.textView.textContainerOrigin.y
    let remainingSpace = editor.scrollView.contentView.bounds.maxY - caretBottom
    XCTAssertGreaterThanOrEqual(remainingSpace, editor.textView.bottomOverscroll - 1)
}
```

`makeEditor` 必须在断言前调用 `layoutManager.ensureLayout(for:)`，并返回 `scrollView`、`textView` 和末个 glyph 行下边缘。允许 1pt 浮点误差；不得将 text view 的 frame 或 clip bounds 直接手工伪造为“已滚动”，否则测试无法覆盖 AppKit 的实际文本布局。

**Step 4: 运行测试并记录 red 状态**

Run:

```bash
swift test --filter SyntaxHighlightedEditorScrollTests
```

Expected: 几何测试因符号缺失失败；AppKit 测试可在编译后运行时失败，因为 `lineFragmentBounds` 和 `bottomOverscroll` 尚未恢复。若测试宿主无法初始化 AppKit，先在测试 setup 中调用 `NSApplication.shared`，再重跑；不要删去 AppKit 测试或用纯字符串测试替代。

### Task 2：恢复末行可见性与高亮恢复保护

**Files:**

- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift:136-208,294-300,419-424,466-501,578-674`
- Test: `Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift`

**Step 1: 添加内部滚动几何 helper，使高亮恢复可确定性测试**

在 `HighlightableTextView` 前添加内部（不标记 `public`）`EditorScrollGeometry`，只承载数值钳制：

```swift
enum EditorScrollGeometry {
    static func restoredOrigin(
        targetY: CGFloat,
        viewportHeight: CGFloat,
        documentHeight: CGFloat,
        bottomInset: CGFloat,
        caretTop: CGFloat?,
        caretBottom: CGFloat?,
        bottomOverscroll: CGFloat
    ) -> CGFloat {
        let maxY = max(0, documentHeight - viewportHeight + bottomInset)
        var origin = max(0, min(targetY, maxY))

        guard let caretTop, let caretBottom else { return origin }
        if caretBottom > origin + viewportHeight {
            origin = min(maxY, caretBottom - viewportHeight + bottomOverscroll)
        } else if caretTop < origin {
            origin = max(0, caretTop)
        }
        return origin
    }
}
```

注意：参数均处于 text view 坐标系；调用端负责把 `lineFragmentBounds` 加上 `textContainerOrigin.y`。helper 不创建或修改 `NSView`，不读取全局状态，也不处理动画。

**Step 2: 恢复 `HighlightableTextView` 的末行行为**

在类中恢复下列最小 API：

- `var bottomOverscroll: CGFloat = 0`；
- `lineFragmentBounds(for:)`：先 `ensureLayout(for: textContainer)`；当 range 位于文末时优先返回非零高的 `extraLineFragmentUsedRect`，否则回退到最后一个 glyph 的 `lineFragmentUsedRect`；
- `scrollRangeToVisible(_:)` 在未抑制时先调用 `super`，再调用私有 `keepLastLineAboveBottomEdge(_:)`；
- 私有方法只处理 `range.location >= textLength - 1`，不足 `bottomOverscroll` 时以 `contentView.setBoundsOrigin` 与 `reflectScrolledClipView` 补足末行下方间隙。

不得给 `NSScrollView`、`NSClipView` 或 SwiftUI 外层设置 `contentInsets`；它由系统布局维护，主动写入会改变 `visibleRect` 并重现钳制漂移。

**Step 3: 在创建与更新路径同步一行留白高度**

在 `makeNSView` 中、设置 `textContainerInset` 后，以当前等宽字体计算：

```swift
let lineHeight = textView.layoutManager?.defaultLineHeight(for: defaultFont) ?? (fontSize * 1.5)
textView.bottomOverscroll = ceil(lineHeight)
```

在 `updateNSView` 的 inset 更新后，使用当前 `fontSize` 的同样计算更新 `bottomOverscroll`，但仅当差值大于 0.01 时写入。`textContainerInset` 继续完全遵从 `contentPadding`；不要为此功能改动全局内容边距或持久化设置。

**Step 4: 修正跳转行的真实视口与下界**

在 `scrollToLineInTextView` 中：

```swift
let visibleHeight = scrollView.contentView.bounds.height
let maxY = max(0, documentHeight - visibleHeight + scrollView.contentView.contentInsets.bottom)
let clampedY = max(0, min(adjustedY, maxY))
```

保留现有 1/3 位置与 0.3 秒动画；不要改变大纲请求的清除时机、行号换算或 Rendered WebView 的滚动逻辑。

**Step 5: 修正语法高亮恢复路径并保护插入点**

在 `Coordinator.reapplyHighlights()` 中：

1. 将 `visibleHeight` 改为 `scrollView.contentView.bounds.height`；
2. 从已保存的 `selectedRange.location` 构造零长度 `insertionRange`，使用 `textView.lineFragmentBounds(for:)` 得到插入点行；
3. 将该行的 top/bottom 转为 text view 坐标，传入 `EditorScrollGeometry.restoredOrigin(...)`；
4. 将返回值作为唯一的 `clampedY` 写入 `contentView`；
5. 保持原有顺序：先固定 bounds，再恢复 selection；`suppressAutoScroll` 仍包住整段高亮恢复；最后一帧校验仍比较同一个 `clampedY`。

不得取消 50ms 防抖、删除 final bounds 校验、改动语法高亮属性、搜索高亮重叠顺序、per-file undo 或文件内容同步策略。

**Step 6: 运行针对性测试，确认 green**

Run:

```bash
swift test --filter SyntaxHighlightedEditorScrollTests
swift test --filter SyntaxHighlightedEditorSyncTests
```

Expected: 两个筛选套件全部通过。新测试需同时证明：末行留白不少于一行、文末换行走 extra line fragment、插入点位于下方时恢复位置下移、普通可见行不移动、下界不会超过 `documentHeight - viewportHeight + bottomInset`。

**Step 7: 提交单一可回退的修复提交**

```bash
git add \
  Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift \
  Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift
git commit -m "fix: prevent editor bottom scroll jitter"
```

预期：提交只包含一个生产文件和一个测试文件；不可混入分栏预览、Settings、WebView、Release Notes 或用户工作区文件。

### Task 3：执行完整回归与人工复现矩阵

**Files:**

- Modify: 无。
- Verify: `SyntaxHighlightedEditor.swift` 的 Raw 编辑路径、既有编辑器同步合同。

**Step 1: 执行构建与完整测试**

Run:

```bash
swift test
swift build
swift build -c release
git diff --check HEAD~1..HEAD
git status --short --branch
```

Expected: 所有命令成功，`git diff --check` 无输出，worktree 除计划中的已提交修复外保持干净。任何失败均为合入阻断项；不得因问题“只在 GUI 出现”跳过测试或 release build。

**Step 2: 执行 Raw 编辑人工回归矩阵**

在本分支构建的 app 中，使用窗口高度仅显示约 8–12 行的长 Markdown 文件，逐项记录实际结果：

1. 光标移至文末，连续回车 5–10 次并输入短文本；每次 50ms 高亮后插入点保持可见，末行下方约保留一行，不上下闪动。
2. 文件以换行结尾，在新增的空行继续输入；光标使用 extra line fragment，仍保持可见。
3. 文件末尾添加 `## END`，从中段在右侧大纲点击 `END`，立刻连续回车/输入；跳转动画完成后没有被高亮恢复拉回。
4. 在文档中段连续输入、搜索下一项、切换主题与调节字号；没有多余底部跳动、焦点丢失、搜索高亮丢失或内容回写异常。
5. 在 Raw/Rendered 间切换及切换两个文件；不改变既有滚动请求清理、每文件 undo 或内容同步行为。

**Step 3: 记录验收结果并决定集成**

验收必须同时满足：

- 自动化测试覆盖末行、文末换行、插入点越过下边缘、上边缘与最大滚动下界；
- 上述五项 GUI 矩阵全部通过；
- 修改范围严格为两份文件；
- 未恢复 `defaultSplitPreview`、`WindowSession`、`DetailView`、`SettingsView`、WebView 调度或任何 v2.3.0 分栏功能。

若任一 GUI 项仍抖动，停止合入，保存屏幕录制与文档末尾内容，回到 Task 1 以实际 bounds、selection range 和 line fragment 值定位；不得继续叠加更多自动滚动补丁。

## 三、失败处理与回滚

- AppKit 测试在 CI/headless 宿主无法创建 window：保留测试，先将 setup 收敛为最小 `NSApplication.shared` 与离屏 window；不得删除覆盖真实 `NSTextView` 布局的测试或用字符串数学断言冒充。
- 修复导致中段滚动、搜索定位或大纲跳转回归：执行 `git revert <fix-commit>`，恢复 v2.3.1 行为；不 reset、force-push 或移动历史 tag。
- 只出现“留白不够”但没有插入点丢失：重新检查字体行高、extra line fragment 与系统 bottom inset；不要通过放大全局 `contentPadding` 处理。
- 未指定发行版本：本计划止于可审查的修复提交，不创建 tag、Release、DMG/ZIP、Homebrew Cask 或公开发行说明。

## 四、不包含

- 不恢复或重做 v2.3.0 / PR #14 的左右分栏实时预览、200ms 预览防抖、`defaultSplitPreview` 设置或本地化文案。
- 不修改 `SettingsModel.swift`、`WindowSession.swift`、`DetailView.swift`、`SettingsView.swift`、`WebViewMarkdownView.swift`、`RawMarkdownView.swift`、PDF/Quick Look 或文件监控。
- 不更改 Markdown 语法高亮规则、50ms 高亮防抖时长、搜索高亮覆盖顺序、per-file undo、文件同步策略或大纲行号语义。
- 不修改用户文档、UserDefaults、Git 历史、tag、已有 Release、构建/签名/更新机制；发行版本、CHANGELOG 和发布流程另行决定。
