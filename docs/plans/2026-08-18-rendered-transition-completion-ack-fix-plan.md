# 渲染模式过渡完成回执修复 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复 Raw 编辑内容后首次切回 Rendered 仍停留在编辑视图的问题：仅在 WebView 确认已替换正文后结束 Raw 过渡层。

**Architecture:** 为 MR.replaceContent 建立显式 Boolean 成功回执：找到 mr-content、完成正文替换和现有后处理时返回 true；目标节点不存在返回 false。Swift 侧将 JavaScript 返回值与 latest-wins generation 一并交给纯完成策略，只有 true 且 generation 仍是当前请求时才通知 DetailView 结束过渡。异常、false、nil、过期 generation 都保持 Raw 过渡层，不把旧内容或空白 WebView 露给用户。

**Tech Stack:** Swift 6.2、SwiftUI、WebPage/WebKit、原生 JavaScript、XCTest、Swift Package Manager。

---

## 一、问题与范围

### 根因

分支 codex/rendered-mode-no-blank 已让 Raw -> Rendered 过渡等待 WebView 的 onRenderGenerationCompleted 回调。增量路径调用 MR.replaceContent 后使用 result != nil 判断 JavaScript 成功；但当前 MR.replaceContent 没有 return，因此成功调用的返回值是 undefined / nil。内容已实际写入 DOM，却不会发出完成回调，Raw 过渡层持续覆盖 WebView。用户再来一次模式切换才可能经其它路径离开该状态。

### 成功标准

- 渲染 -> 编辑 -> 修改 Markdown -> 渲染：首次切回即可显示最新渲染内容。
- 不依赖再次切换模式、固定延迟或 reload 图标。
- JavaScript 目标节点不存在、调用异常、返回 false 或请求世代过期时，绝不错误结束过渡。
- Mermaid/KaTeX 运行时需求变化的整页加载路径保持原有 page.isLoading 完成机制，不改为增量回执。
- 不修改 codex/rendered-raw-source-position 分支的双向位置同步内容。

### 不包含

- 不处理 Raw/Rendered 位置同步、大纲跳转、cursorLineNumber 或 scrollToLineRequest。
- 不改 DocumentViewModel、DetailView 的过渡状态机、WebView 保活策略、文件监控或 reload 图标语义。
- 不做 Markdown / WebView 磁盘缓存，不恢复分栏预览，不新增第二个 WebView 或输入防抖。
- 不改 Mermaid、KaTeX、Prism、PDF、Quick Look、主题、复制按钮或 URL scheme handler。

## 二、完成协议

    Swift replaceContent(generation N)
      -> await MR.replaceContent(html)
           -> false：未找到 #mr-content
           -> true：innerHTML 已替换，既有 Mermaid/PlantUML/KaTeX/Prism 后处理已调用
      -> WebViewContentReplacementCompletionPolicy
           -> true 且 generation N 仍最新：onRenderGenerationCompleted(N)
           -> false / nil / throw / stale：不回调

此协议只证明增量替换入口完成；它不要求 Mermaid 异步绘制结束，也不改变运行时需求变化时升级为整页 page.load 的既有策略。

## 三、实施任务

### Task 0：建立隔离基线并记录 red 行为

**Files:**

- Create: 无。
- Verify: Sources/MarkdownReader/Resources/js/markdown-reader.js、Sources/MarkdownReader/Views/WebViewMarkdownView.swift、Sources/MarkdownReader/Views/WebViewRenderScheduler.swift、Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift。

**Step 1: 建立干净 worktree**

    git status --short --branch
    git fetch origin codex/rendered-mode-no-blank
    git worktree add -b codex/rendered-transition-completion-ack ../MarkdownReader-rendered-transition-completion-ack codex/rendered-mode-no-blank
    cd ../MarkdownReader-rendered-transition-completion-ack
    git status --short --branch
    git log -1 --oneline

Expected: 新 worktree 无修改，基线包含 8d4921c 或其后续等价提交。不要从 main 或 codex/rendered-raw-source-position 开始，也不带入原工作区未跟踪的计划文档。

**Step 2: 记录当前失败**

运行：

    swift run MarkdownReader

打开普通 Markdown，Rendered -> Raw，编辑一个字符后切回 Rendered。确认内容虽已替换、但 Raw 过渡层未退出；再切一次模式才显示正常。该观察只用于确认 red，不提交样本文档或截图。

### Task 1：先为 Swift 完成判定写失败测试

**Files:**

- Modify: Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
- Modify: Sources/MarkdownReader/Views/WebViewRenderScheduler.swift

**Step 1: 写失败测试**

在 WebViewRenderSchedulerTests.swift 增加：

    func testReplacementCompletionRequiresTrueJavaScriptAcknowledgement() {
        XCTAssertTrue(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: true, isCurrentGeneration: true
        ))
    }

    func testReplacementCompletionRejectsFalseNilAndUnexpectedResult() {
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: false, isCurrentGeneration: true
        ))
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: nil, isCurrentGeneration: true
        ))
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: "true", isCurrentGeneration: true
        ))
    }

    func testReplacementCompletionRejectsSuccessfulButStaleGeneration() {
        XCTAssertFalse(WebViewContentReplacementCompletionPolicy.shouldComplete(
            javaScriptResult: true, isCurrentGeneration: false
        ))
    }

**Step 2: 确认 red**

    swift test --filter WebViewRenderSchedulerTests

Expected: 编译失败，缺少 WebViewContentReplacementCompletionPolicy。不得先改生产代码或 JavaScript。

**Step 3: 最小实现**

在 WebViewRenderScheduler.swift 新增纯策略：

    enum WebViewContentReplacementCompletionPolicy {
        static func shouldComplete(
            javaScriptResult: Any?,
            isCurrentGeneration: Bool
        ) -> Bool {
            isCurrentGeneration && (javaScriptResult as? Bool == true)
        }
    }

不要把 WebPage、Task、SwiftUI View 或 callback 放进该策略。JavaScript API 的返回值必须是明确 Boolean，不能把任意非 nil 值、字符串 true 或异常吞掉后当作成功。

**Step 4: 确认 green**

    swift test --filter WebViewRenderSchedulerTests

Expected: 新增的 true / false / nil / 非 Boolean / stale 断言和既有 scheduler tests 均通过。

**Step 5: Commit**

    git add Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
    git commit -m "test: require explicit replacement acknowledgement"

### Task 2：让 JavaScript 返回显式回执并接入 Swift 策略

**Files:**

- Modify: Sources/MarkdownReader/Resources/js/markdown-reader.js:41-55
- Modify: Sources/MarkdownReader/Views/WebViewMarkdownView.swift:447-464
- Test: Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift

**Step 1: 为 JavaScript 回执定义最小合同**

把 MR.replaceContent 的控制流改为：

    replaceContent(html) {
      const content = document.getElementById('mr-content');
      if (!content) return false;

      content.innerHTML = html;
      MR._searchHighlights = [];
      MR.renderMermaid();
      MR.renderPlantUML();
      MR.renderKaTeX();
      MR.renderAdmonitions();
      MR.addCopyButtons();
      if (typeof Prism !== 'undefined') {
        Prism.highlightAll();
      }
      return true;
    }

不得移动既有后处理调用、改变其顺序、吞掉后处理的 JavaScript 异常，或为兼容旧调用者保留 undefined 返回值。

**Step 2: 将 replaceContent 改为 do/catch 加显式策略**

保留当前创建 Task、Task cancellation 和 generation 检查。把 try? + result != nil 替换为：

    do {
        let result = try await page.callJavaScript(
            "MR.replaceContent('\(escapedHTML)')"
        )
        guard !Task.isCancelled,
              WebViewContentReplacementCompletionPolicy.shouldComplete(
                  javaScriptResult: result,
                  isCurrentGeneration: renderScheduler.accepts(generation)
              ) else {
            return
        }
        onRenderGenerationCompleted?(generation)
    } catch {
        return
    }

根据最终 API 返回类型调整 result 的 Optional 包装，但不改变上述语义：只有显式 true 且 generation 仍最新才能完成。catch 不打印用户可见错误、不结束过渡，也不创建重试或 reload 状态。

**Step 3: 运行自动验证**

    swift test --filter WebViewRenderSchedulerTests
    swift build

Expected: focused tests 和主 target 均通过。若 Swift 6 对 Task 内捕获、Any? 或 actor isolation 报错，先写一个最小 failing test 或编译复现，再修正类型边界；不要用强制转换或 force unwrap。

**Step 4: Commit**

    git add Sources/MarkdownReader/Resources/js/markdown-reader.js Sources/MarkdownReader/Views/WebViewMarkdownView.swift Sources/MarkdownReader/Views/WebViewRenderScheduler.swift Tests/MarkdownReaderTests/WebViewRenderSchedulerTests.swift
    git commit -m "fix: acknowledge completed rendered content replacement"

### Task 3：端到端回归验证

**Files:**

- Modify: 无；若发现 bug，先补针对该 bug 的 red 测试，再最小修复。
- Verify: Task 2 的四个文件。

**Step 1: 全量自动验证**

    swift test
    swift build
    swift build -c release
    git diff --check
    git status --short

Expected: 前四项成功，git diff --check 无输出；worktree 仅含本任务预期改动。

**Step 2: GUI 验收**

    swift run MarkdownReader

| 场景 | 期望 |
|---|---|
| 普通 Markdown：Rendered -> Raw，编辑文字，再 Rendered | 首次切回就显示最新内容；不白屏、不停留在 Raw。 |
| Raw 连续编辑后立即 Rendered | 最后一次内容生效；旧 generation 不可提前结束过渡。 |
| Raw 中新增 Mermaid 或 KaTeX 后 Rendered | 走现有整页加载；Raw 作为只读过渡画面，最终显示正确结果。 |
| 不编辑直接 Raw -> Rendered | 已就绪页面正常显示，不改变现有 none / page.isLoading 路径。 |
| JS 目标节点不存在或调用抛错的调试注入 | 过渡不得错误结束；移除注入后应用可恢复正常。 |
| 保存、外部文件修改、reload 图标、PDF、查找、大纲、缩放 | 既有行为不变。 |

Task 3 没有代码变化时不创建空提交。

## 四、回滚

本任务的可回滚范围仅为一个或两个提交，涉及 markdown-reader.js、WebViewMarkdownView.swift、WebViewRenderScheduler.swift 与其测试。若显式回执导致某环境的 JavaScript bridge 类型不兼容、正常内容不能完成过渡或引入新崩溃，回滚这些提交即可恢复 8d4921c 前的行为；不回滚 WebView 常驻方案，也不合并或回滚 codex/rendered-raw-source-position。
