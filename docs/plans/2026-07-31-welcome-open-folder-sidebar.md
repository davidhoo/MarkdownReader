# Welcome Open Folder Sidebar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure that choosing a folder from the welcome page opens it in the current blank window with the Sidebar visible.

**Architecture:** Keep the Sidebar subtree alive for ordinary show/hide operations, but key its SwiftUI identity to the root-directory context. Entering directory mode from the welcome page then rebuilds the previously zero-width subtree without changing routing or `Cmd+\` behavior.

**Tech Stack:** Swift 6, SwiftUI Observation, Swift Concurrency, XCTest, Swift Package Manager

---

### Task 1: Capture the Sidebar directory-context identity

**Files:**
- Modify: `Tests/MarkdownReaderTests/OpenDirectorySidebarTests.swift`

**Step 1: Write the failing test**

Add a model test asserting that the Sidebar presentation identity changes from welcome to a directory, stays stable when reopening the same directory, and changes when switching root directories. Add an `NSHostingView` layout test that measures the real Sidebar geometry, verifies the subtree is rebuilt on directory entry, and verifies ordinary hide/show reuses it.

**Step 2: Run the test to verify it fails**

Run:

```bash
swift test --filter OpenDirectorySidebarTests/testSidebarPresentationIdentityChangesWhenDirectoryContextChanges
```

Expected: FAIL to compile because `sidebarPresentationIdentity` does not exist.

### Task 2: Rebuild Sidebar when its directory context changes

**Files:**
- Modify: `Sources/MarkdownReader/ViewModels/AppViewModel.swift`
- Modify: `Sources/MarkdownReader/Views/ContentView.swift`
- Test: `Tests/MarkdownReaderTests/OpenDirectorySidebarTests.swift`

**Step 1: Write the minimal implementation**

Expose a stable presentation identity derived from `rootDirectory`, then apply it with `.id(...)` to the framed `SidebarView`. Show the Sidebar synchronously when entering directory mode so an OpenPanel sheet transition cannot leave the width animation at zero. Add a non-hit-testable AppKit geometry probe after the frame modifier for regression measurement. Do not key the view to `isSidebarVisible`, so ordinary toggles continue to preserve the subtree and their animation.

**Step 2: Run the focused test**

Run:

```bash
swift test --filter OpenDirectorySidebarTests/testSidebarPresentationIdentityChangesWhenDirectoryContextChanges
```

Expected: PASS.

**Step 3: Run the Sidebar regression suite**

Run:

```bash
swift test --filter OpenDirectorySidebarTests
```

Expected: all tests PASS.

### Task 3: Verify the complete change

**Files:**
- Verify: `Sources/MarkdownReader/ViewModels/AppViewModel.swift`
- Verify: `Sources/MarkdownReader/Views/ContentView.swift`
- Verify: `Tests/MarkdownReaderTests/OpenDirectorySidebarTests.swift`

**Step 1: Run the full test suite**

Run:

```bash
swift test
```

Expected: all tests PASS with no unexpected failures.

**Step 2: Build the application**

Run:

```bash
swift build
```

Expected: build succeeds.

**Step 3: Check patch hygiene**

Run:

```bash
git diff --check
```

Expected: no output.
