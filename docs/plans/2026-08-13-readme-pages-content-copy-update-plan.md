# README 与 GitHub Pages 内容复制功能同步 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 v2.2.5–v2.2.10 已发布的整篇内容复制能力，以及普通文档的按需运行时加载收益，同步到四语 README、GitHub Pages 首页和帮助页，使公开介绍与当前产品一致。

**Architecture:** README 保持为紧凑功能清单，仅增加一行用户可见能力和一行性能收益。GitHub Pages 继续由单一功能卡片模板和四份 i18n YAML 驱动：首页新增内容复制卡片，帮助页在现有 Quick Look / PDF 区域增加复制说明卡片；不向页面暴露 WebKit 调度、SF Symbol 栅格化或安全作用域等实现细节。

**Tech Stack:** Markdown、Jekyll / Liquid、YAML、GitHub Pages（`github-pages` gem）

---

## 已确认的产品文案边界

- “整篇内容一键复制”适用于主阅读渲染模式、Raw 原文模式和 Quick Look；设置中的总开关可统一关闭三处复制入口。
- Quick Look 在总开关开启时可选择“富文本”或“原始 Markdown 文本”：前者保留标题、强调、表格、代码等渲染结构，后者逐字复制 UTF-8 Markdown 原文。
- “按需加载”只说明普通 Markdown 不再加载未使用的图表/公式运行时，从而更轻快；不可承诺具体启动时间、内存百分比或文件大小。
- v2.2.5–v2.2.10 的具体实现、修复与测试已经在 `CHANGELOG.md` 和 `docs/releases/` 中记录，本任务不重复修改它们。

## 文案基线

各语言采用与现有页面一致的简洁产品表述，实施时可做自然语言润色，但含义不得扩张：

| 语言 | 首页卡片标题 | 首页说明 |
|---|---|---|
| 简体中文 | 内容一键复制 | 一键复制整篇内容；可在设置中关闭，Quick Look 支持富文本或原始 Markdown。 |
| 繁體中文 | 內容一鍵複製 | 一鍵複製整篇內容；可在設定中關閉，Quick Look 支援富文字或原始 Markdown。 |
| English | Copy Document Content | Copy an entire document in one click. Turn it off in Settings; Quick Look supports rich text or raw Markdown. |
| 日本語 | 文書をワンクリックでコピー | 文書全体をワンクリックでコピー。設定で無効化でき、Quick Look ではリッチテキストまたは元の Markdown を選べます。 |

README 的两条新增条目使用各语言相同语义：

1. 整篇内容复制与 Quick Look 的两种格式选择。
2. Mermaid / KaTeX 等可选运行时仅在文档需要时加载，普通 Markdown 阅读更轻快。

### Task 1: 扩展 Pages 四语言文案键

**Files:**
- Modify: `pages/_data/i18n/zh-CN.yml:14-38,145-150`
- Modify: `pages/_data/i18n/zh-TW.yml:14-38,145-150`
- Modify: `pages/_data/i18n/en.yml:14-38,145-150`
- Modify: `pages/_data/i18n/ja.yml:14-38,145-150`

**Step 1: 定义首页卡片键**

在每份 YAML 的 `# Features` 段落中增加、且仅增加以下成对键：

```yaml
feature_document_copy_title: "..."
feature_document_copy_desc: "..."
```

四种语言的键名必须完全一致；值使用“文案基线”中的用户可见含义，不提及 JavaScript bridge、SF Symbols 或内部复制实现。

**Step 2: 定义帮助页说明键**

在既有 `feat_ql_*` / `feat_export_*` 相邻的“更多功能”键组中新增：

```yaml
feat_document_copy_title: "..."
feat_document_copy_desc: "..."
```

说明必须包含：设置中的总开关、主阅读/原文/Quick Look 的覆盖范围，以及 Quick Look 的富文本 / 原始 Markdown 两种格式。不要宣称总开关关闭后会改变文件内容或剪贴板历史。

**Step 3: 静态检查四语言覆盖**

Run:

```bash
for file in pages/_data/i18n/{zh-CN,zh-TW,en,ja}.yml; do
  printf '%s: ' "$file"
  rg -c '^feature_document_copy_(title|desc):|^feat_document_copy_(title|desc):' "$file"
done
```

Expected: 每个文件均输出 `4`；不应有缺失语言或重复键。

**Step 4: Commit**

```bash
git add pages/_data/i18n/zh-CN.yml pages/_data/i18n/zh-TW.yml pages/_data/i18n/en.yml pages/_data/i18n/ja.yml
git commit -m "docs: add document copy website copy"
```

### Task 2: 在 Pages 首页展示内容复制卡片

**Files:**
- Modify: `pages/_includes/features.html:4-82`
- Test: `pages/_data/i18n/{zh-CN,zh-TW,en,ja}.yml`（Task 1 的键完整性检查）

**Step 1: 添加一个复用现有样式的功能卡片**

在 `features-grid` 内新增恰好一个 `.feature-card`。沿用现有内联 SVG 图标写法，选择语义为“双文档 / 复制”的简洁线性图标；不新增 CSS、图片资源或 JavaScript。

卡片标题和说明必须仅通过 Liquid 键读取：

```liquid
{{ include.t.feature_document_copy_title }}
{{ include.t.feature_document_copy_desc }}
```

**Step 2: 检查模板不硬编码新文案**

Run:

```bash
rg -n 'feature_document_copy_(title|desc)' pages/_includes/features.html
rg -n '内容一键复制|Copy Document Content|文書をワンクリック' pages/_includes/features.html
```

Expected: 第一条命令各命中一次；第二条命令无输出，确保翻译仅维护在 i18n 文件中。

**Step 3: Commit**

```bash
git add pages/_includes/features.html
git commit -m "docs: show document copy on website"
```

### Task 3: 在 Pages 帮助页补充可操作说明

**Files:**
- Modify: `pages/help.html:242-262`
- Modify: `pages/en/help.html:235-255`
- Modify: `pages/zh-TW/help.html:242-262`
- Modify: `pages/ja/help.html:235-255`
- Test: `pages/_data/i18n/{zh-CN,zh-TW,en,ja}.yml`（Task 1 的键完整性检查）

**Step 1: 在四份帮助页增加复制卡片**

在既有 `id="quicklook"` 的“更多功能”网格中，在 Quick Look 与导出 PDF 卡片之间插入一个内容复制卡片。四份 HTML 结构保持平行，只改变各自行号和页面 front matter，不创建新的锚点或目录项。

卡片结构遵循现有 HTML：

```html
<div class="feature-card">
  <div class="feature-icon">
    <!-- 与首页语义一致的复制图标 -->
  </div>
  <h3 class="feature-title">{{ t.feat_document_copy_title }}</h3>
  <p class="feature-desc">{{ t.feat_document_copy_desc }}</p>
</div>
```

**Step 2: 检查四个页面均引用 i18n 文案**

Run:

```bash
rg -l 'feat_document_copy_(title|desc)' pages/help.html pages/en/help.html pages/zh-TW/help.html pages/ja/help.html
```

Expected: 输出恰好四个帮助页路径。

**Step 3: Commit**

```bash
git add pages/help.html pages/en/help.html pages/zh-TW/help.html pages/ja/help.html
git commit -m "docs: document content copy in Pages help"
```

### Task 4: 同步四语 README 与 Pages 维护版本

**Files:**
- Modify: `README.md:28-45`
- Modify: `README.zh-TW.md:28-45`
- Modify: `README.en.md:28-45`
- Modify: `README.ja.md:28-45`
- Modify: `pages/_config.yml:22-29`

**Step 1: 为每份 README 添加两项功能说明**

在功能表中加入两行，按既有术语和表格格式翻译：

```markdown
| 整篇内容复制 | 渲染模式、原文模式与 Quick Look 可一键复制整篇内容；设置可统一关闭，Quick Look 可选富文本或原始 Markdown。 |
| 按需加载 | Mermaid、KaTeX 等可选组件仅在文档需要时加载，普通 Markdown 阅读更轻快。 |
```

位置应靠近现有 “Quick Look preview” 和渲染能力条目；四份 README 保持同一功能集合与表格顺序。不得修改安装、Homebrew、Gatekeeper 或系统要求说明。

**Step 2: 更新 Pages 维护版本**

将 `pages/_config.yml` 的值同步到当前已发布标签：

```yaml
app:
  version: "2.2.10"
```

不修改 `macos_version`、下载 URL、仓库 URL 或许可证。

**Step 3: 检查 README 覆盖与配置值**

Run:

```bash
for file in README.md README.zh-TW.md README.en.md README.ja.md; do
  printf '%s: ' "$file"
  rg -c '复制|コピー|Copy' "$file"
done
rg -n 'version: "2\.2\.10"' pages/_config.yml
```

Expected: 每份 README 的匹配数相较修改前增加；配置命令精确命中一行。人工复核四种语言是否均同时提到开关和 Quick Look 的两种格式。

**Step 4: Commit**

```bash
git add README.md README.zh-TW.md README.en.md README.ja.md pages/_config.yml
git commit -m "docs: sync README and Pages version"
```

### Task 5: 构建、人工核对并交付

**Files:**
- Verify: `pages/_includes/features.html`
- Verify: `pages/help.html`, `pages/en/help.html`, `pages/zh-TW/help.html`, `pages/ja/help.html`
- Verify: `pages/_data/i18n/zh-CN.yml`, `pages/_data/i18n/zh-TW.yml`, `pages/_data/i18n/en.yml`, `pages/_data/i18n/ja.yml`
- Verify: `README.md`, `README.zh-TW.md`, `README.en.md`, `README.ja.md`, `pages/_config.yml`

**Step 1: 运行格式与引用完整性检查**

Run:

```bash
git diff --check HEAD~4..HEAD
for file in pages/_data/i18n/{zh-CN,zh-TW,en,ja}.yml; do
  ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0)); puts "OK #{ARGV.fetch(0)}"' "$file"
done
rg -n 'feature_document_copy_(title|desc)|feat_document_copy_(title|desc)' pages
```

Expected: `git diff --check` 无输出；四份 YAML 均输出 `OK`；所有新增 Liquid 引用都有对应 i18n 定义。

**Step 2: 构建 GitHub Pages**

Run:

```bash
cd pages && bundle exec jekyll build
```

Expected: exit code 0，并生成 `pages/_site/`；无 Liquid 未定义变量、YAML 解析或页面构建错误。

**Step 3: 人工浏览四种语言页面**

通过本地 Jekyll 预览或构建产物确认：

- 首页四种语言都出现内容复制卡片，卡片网格未溢出；
- 帮助页四种语言都在 Quick Look / PDF 相邻区域出现复制说明；
- 翻译没有显示为 Liquid 原始键、没有出现空标题或空描述；
- README 四个版本的功能表都含相同两项新增能力；
- 页面不出现未验证的性能数值或工程内部术语。

**Step 4: 最终提交（若前述任务按单一提交实施）**

若没有按任务分提交，改为一次原子提交：

```bash
git add README.md README.zh-TW.md README.en.md README.ja.md pages
git commit -m "docs: sync content copy feature across public docs"
```

## 验收标准

1. README 的简中、繁中、英文、日文版本均包含“整篇内容复制”和“按需加载”的用户价值说明，且不破坏现有安装与发行说明。
2. Pages 首页四种语言均新增内容复制功能卡片，文案均来自对应 i18n 文件。
3. Pages 帮助页四种语言均清楚说明设置总开关和 Quick Look 的富文本 / 原始 Markdown 格式选择。
4. `pages/_config.yml` 中 `app.version` 为 `2.2.10`，其他 app 元数据不变。
5. YAML 解析通过、`bundle exec jekyll build` 成功、`git diff --check` 无输出。
6. `CHANGELOG.md`、`docs/releases/`、Swift 源码、应用资源和发布工作流均不在变更中。

## 不包含

- 不新增或修改内容复制、Quick Look、渲染调度、运行时加载的应用实现与测试。
- 不改首页截图、页面布局系统、CSS、主题资源或下载流程。
- 不把 SF Symbols、WebView latest-wins、security-scoped access、JS bridge、运行时资源体积等内部细节写入 README 或 Pages。
- 不改 `CHANGELOG.md`、已有 Release Notes，不新建发布或部署；合入 `main` 后由现有 `deploy-pages.yml` 自动部署。
