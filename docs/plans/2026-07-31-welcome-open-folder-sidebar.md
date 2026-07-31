# Welcome Open Folder Sidebar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure that choosing a folder from the welcome page opens it in the current blank window with the Sidebar visible.

**Architecture:** Preserve the existing separation of responsibilities: the welcome page initiates the OpenPanel command, the coordinator routes the selected resource, and `WindowSession.openDirectory` establishes directory-mode UI invariants before loading the tree. Add an integration-style regression test for the `.openPanel` route instead of source-specific production branching.

**Tech Stack:** Swift 6, SwiftUI Observation, Swift Concurrency, XCTest, Swift Package Manager

---

### Task 1: Reproduce the welcome-page OpenPanel route

**Files:**
- Modify: `Tests/MarkdownReaderTests/OpenDirectorySidebarTests.swift`

**Step 1: Write the failing test**

Add a test that creates a ready `WindowCoordinator`, registers a blank `WindowSession`, submits an `.openPanel` directory request with `preferredWindowID: session.id`, waits for the routed main-actor task, and asserts that the current session owns the directory, has the expected `rootDirectory`, shows the Sidebar, and has loaded the directory tree.

**Step 2: Run the test to verify it fails**

Run:

```bash
swift test --filter OpenDirectorySidebarTests/testWelcomeOpenPanelDirectoryShowsSidebarInCurrentWindow
```

Expected: FAIL because the complete OpenPanel routing path does not yet preserve the Sidebar invariant.

### Task 2: Enforce the directory-mode Sidebar invariant

**Files:**
- Modify: `Sources/MarkdownReader/ViewModels/WindowSession.swift`
- Test: `Tests/MarkdownReaderTests/OpenDirectorySidebarTests.swift`

**Step 1: Write the minimal implementation**

At the `WindowSession.openDirectory` boundary, synchronously establish directory mode and explicitly ensure the Sidebar is visible before awaiting directory-tree loading. Reuse `AppViewModel` behavior; do not add `.openPanel` source checks or mutate the Sidebar from `WelcomeView`.

**Step 2: Run the focused test**

Run:

```bash
swift test --filter OpenDirectorySidebarTests/testWelcomeOpenPanelDirectoryShowsSidebarInCurrentWindow
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
- Verify: `Sources/MarkdownReader/ViewModels/WindowSession.swift`
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
