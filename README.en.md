[简体中文](README.md) | [繁體中文](README.zh-TW.md) | **[English](README.en.md)** | [日本語](README.ja.md)

# Markdown Reader

> Not another all-in-one editor, just a quiet reader.
![screenshot](screenshot.png)

![macOS 26+](https://img.shields.io/badge/macOS-26+-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## Why This One?

There are more and more Markdown tools out there, each packed with features — real-time collaboration, cloud sync, plugin ecosystems... But most of the time, you just want to **quickly open a .md file and read it quietly**.

Markdown Reader is built for exactly that:

- **Zero friction** — No sign-up, no login, no complex configuration. Just open and read
- **Instant launch** — Native macOS app. Fast startup, fast switching, smooth reading
- **Focused on reading** — Three-pane layout: file tree + rendered view + outline navigation. See document structure at a glance
- **Tiny and lightweight** — DMG installer under 10MB, takes minimal space

When you don't need writing, collaboration, or fancy features — just want to **quickly view a Markdown document** — this is the right choice.

---

## Features

| Feature | Description |
|---------|-------------|
| WebPage rendering | cmark-gfm + WebPage (native macOS 26) rendering, full GFM extension support |
| Mermaid diagrams | Flowcharts, sequence diagrams, Gantt charts — rendered locally |
| PlantUML diagrams | PlantUML syntax support, auto-renders as SVG (requires network) |
| Math formulas | KaTeX renders LaTeX inline and block formulas |
| Prism.js syntax highlighting | 30+ language syntax highlighting via Prism.js |
| Quick Look preview | Select a .md file in Finder and press Space to preview — no app launch needed |
| Copy document content | Rendered mode, source mode, and Quick Look can copy an entire document in one click. Turn it off in Settings; Quick Look supports rich text or raw Markdown |
| Live editing | Edit in source mode, Cmd+S to save, unsaved content preserved when switching files |
| File tree | Recursively browse folders, keyboard navigation, right-click to create/rename/delete |
| Outline navigation | Auto-extract heading hierarchy, click to jump — efficient for long documents |
| On-demand loading | Optional components like Mermaid and KaTeX load only when a document needs them, keeping plain Markdown reading lighter |
| 33 themes | 20 dark + 13 light, including Markdown Preview Enhanced style themes, with custom color and contrast controls |
| Multi-language | Simplified Chinese, Traditional Chinese, English — auto-follows system |
| CLI tool | `mdr` command to open Markdown files directly from the terminal |
| Command palette | `Cmd+P` to quickly search and open files in the file tree |
| Window restoration | Remembers last browsing position, auto-restores on reopen |

---

## Shortcuts

| Shortcut | Function |
|----------|----------|
| `Cmd+O` | Open folder / file |
| `Cmd+N` | New file |
| `Cmd+S` | Save file |
| `Cmd+Option+E` | Export PDF |
| `Cmd+,` | Open settings |
| `Cmd+\` | Toggle sidebar |
| `Cmd+Shift+E` | Rendered mode |
| `Cmd+Shift+R` | Source mode |
| `Cmd++` | Zoom in |
| `Cmd+-` | Zoom out |
| `Cmd+0` | Actual size |
| `Cmd+F` | Find |
| `Cmd+G` | Find next |
| `Cmd+Shift+G` | Find previous |
| `Cmd+Option+F` | Find and replace |
| `Cmd+P` | Command palette |

---

## Installation

### Download

Go to [Releases](https://github.com/davidhoo/MarkdownReader/releases) to download the latest DMG, then drag it to your Applications folder.

### Homebrew (optional)

You can also install MarkdownReader via a self-hosted Homebrew tap:

```bash
brew tap davidhoo/markdownreader
brew install --cask markdownreader

# Upgrade (the app self-updates, so add --greedy for Homebrew to pull the new version)
brew update
brew upgrade --cask --greedy markdownreader
```

Homebrew only handles installation and optional upgrades; the existing DMG install and in-app update paths remain available and unaffected.

> **About the unnotarized app**: MarkdownReader is development-signed but **not notarized** (no Apple Developer Program). Regardless of how you install it, if macOS blocks the first launch, Control-click MarkdownReader in Applications, choose **Open**, and confirm; or go to **System Settings > Privacy & Security** and click **Open Anyway**. This repo does not provide commands to bypass Gatekeeper.

### System Requirements

macOS 26 (Tahoe) or later.

---

## Official Website

[https://davidhoo.github.io/MarkdownReader/](https://davidhoo.github.io/MarkdownReader/)

---

## Acknowledgments

Markdown Reader is built on the following open-source projects:

- [cmark-gfm](https://github.com/github/cmark-gfm) — GitHub Flavored Markdown parsing and rendering engine
- [swift-markdown](https://github.com/apple/swift-markdown) — Apple's Swift Markdown parsing library (based on cmark-gfm)
- [KaTeX](https://katex.org/) — Fast LaTeX math formula rendering
- [Mermaid](https://mermaid.js.org/) — Text-based diagram generation (flowcharts, sequence diagrams, Gantt charts, etc.)
- [Prism.js](https://prismjs.com/) — Lightweight code syntax highlighting
- [PlantUML](https://plantuml.com/) — Open-source UML diagram rendering

Special thanks to the [linux.do](https://linux.do/) community for their feedback and support.

---

MIT License
