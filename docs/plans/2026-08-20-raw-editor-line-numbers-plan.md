# Raw Editor Line Numbers Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an optional, persisted left gutter with source line numbers to the Raw editor, disabled by default.

**Architecture:** Extend the application settings model with a `showSourceLineNumbers` preference and expose it in Appearance → Typography. Pass that value through `DetailView` and `RawMarkdownView` to `SyntaxHighlightedEditor`. The existing `NSScrollView` remains the SwiftUI-hosted root; a Core Animation overlay layer draws the fixed gutter while the text container inset reserves its left space. The gutter derives labels from `NSLayoutManager` line fragments, so wrapped continuation fragments receive no duplicate label without changing AppKit's content-view layout.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit `NSTextView` / `NSScrollView` / `NSView`, XCTest.

---

### Task 1: Define testable gutter metrics and container layout

**Files:**
- Modify: `Tests/MarkdownReaderTests/SyntaxHighlightedEditorScrollTests.swift`
- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift`

**Step 1: Write the failing test**

Add tests for `LineNumberGutterMetrics.width(lineCount:font:)`: a two-digit document reserves a wider gutter than a one-digit document, and the width includes the fixed horizontal padding. Lock the container contract that both gutter and scroll view remain inside the representable bounds.

**Step 2: Run test to verify it fails**

Run: `swift test --filter SyntaxHighlightedEditorScrollTests/testLineNumber`

Expected: compilation/test failure because the gutter metrics and container layout types do not yet exist.

**Step 3: Write minimal implementation**

Add the pure metric/layout helpers, then use them from a fixed Core Animation gutter overlay on the unchanged scroll view; render only the first visual fragment of each logical source line.

**Step 4: Run test to verify it passes**

Run: `swift test --filter SyntaxHighlightedEditorScrollTests/testLineNumber`

Expected: PASS.

### Task 2: Persist and expose the preference

**Files:**
- Modify: `Sources/MarkdownReader/Models/SettingsModel.swift`
- Modify: `Sources/MarkdownReaderKit/Services/LocalizationService.swift`
- Modify: `Sources/MarkdownReader/Views/SettingsView.swift`
- Modify: `Sources/MarkdownReader/Views/DetailView.swift`
- Modify: `Sources/MarkdownReader/Views/RawMarkdownView.swift`
- Modify: `Sources/MarkdownReader/Views/SyntaxHighlightedEditor.swift`

**Step 1: Write the failing test**

Add an initialization contract test for the new preference’s default value if the existing test setup can isolate `UserDefaults`; otherwise retain the metrics tests as the deterministic unit boundary and verify settings persistence in the app build/manual matrix.

**Step 2: Implement the minimal integration**

Add a `UserDefaults`-backed Boolean defaulting to false, localize the Appearance/Typography toggle in English, Simplified Chinese, and Traditional Chinese, and wire it to the gutter’s visibility and color/font refresh paths.

**Step 3: Verify behavior**

Run focused tests, full `swift test`, `swift build`, `swift build -c release`, and `git diff --check`. Manually confirm initial hidden state, toggle immediate visibility, scrolling, wrapped source lines, theme/font-size changes, and Raw/Rendered switching.

**Not included:** rendered-mode line numbers, a second setting for gutter width/colors, changes to source-position synchronization, highlighter behavior, undo, or bottom-scroll geometry.
