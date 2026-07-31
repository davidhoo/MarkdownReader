# Menu Localization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the macOS standard menu headings follow MarkdownReader's selected application language.

**Architecture:** Correct the main Bundle localization metadata, then add a small AppKit synchronizer for standard top-level menu titles. Keep existing custom `L10n` menu item rendering unchanged.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Swift Testing, Property List

---

### Task 1: Bundle localization regression

**Files:**
- Modify: `scripts/Info.plist`
- Test: `Tests/MarkdownReaderTests/MenuLocalizationTests.swift`

1. Add a test that loads `scripts/Info.plist` and expects development language `en`.
2. Expect `CFBundleLocalizations` to contain `en`, `zh-Hans`, and `zh-Hant`.
3. Run the focused test and confirm it fails against the current `zh-Hans` metadata.
4. Apply the minimal plist change.
5. Run the focused test and confirm it passes.

### Task 2: Standard menu title mapping

**Files:**
- Create: `Sources/MarkdownReader/Services/MainMenuLocalizationService.swift`
- Test: `Tests/MarkdownReaderTests/MenuLocalizationTests.swift`

1. Add failing tests for standard menu titles in all three supported languages.
2. Add failing tests for recognizing menu roles from localized standard titles.
3. Implement the pure title mapping and role recognition.
4. Run the focused tests and confirm they pass.

### Task 3: Runtime synchronization

**Files:**
- Modify: `Sources/MarkdownReader/Services/MainMenuLocalizationService.swift`
- Modify: `Sources/MarkdownReader/App/MarkdownReaderApp.swift`
- Test: `Tests/MarkdownReaderTests/MenuLocalizationTests.swift`

1. Add a failing test that applies a language to an `NSMenu` fixture and verifies only standard headings change.
2. Implement synchronization on the main actor.
3. Invoke synchronization after app startup and when `languagePref.resolvedLanguage` changes.
4. Run the focused tests and confirm they pass.

### Task 4: Full verification

1. Run `swift test`.
2. Run `swift build`.
3. Run `./build-app.sh --release` if the local signing/build environment permits.
4. Inspect the generated `MarkdownReader.app/Contents/Info.plist`.
5. Review `git diff --check` and the final diff.

