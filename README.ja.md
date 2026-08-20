[简体中文](README.md) | [繁體中文](README.zh-TW.md) | [English](README.en.md) | **[日本語](README.ja.md)**

# Markdown Reader

> もう一つの多機能エディタではなく、ただ静かなリーダー。
![screenshot](screenshot.png)

![macOS 26+](https://img.shields.io/badge/macOS-26+-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## なぜこのアプリ？

Markdownツールはますます増え、機能も充実—リアルタイム協業、クラウド同期、プラグインエコシステム……しかし多くの場合、あなたはただ**素早く .md ファイルを開いて、静かに読みたいだけ**なのです。

Markdown Reader はまさにそのために作られました：

- **心理的負担なし** — 登録不要、ログイン不要、複雑な設定なし、開くだけ
- **瞬間起動** — ネイティブ macOS アプリ、高速起動、高速切り替え、スムーズな読書
- **読書に集中** — 3ペインレイアウト：ファイルツリー + レンダリングビュー + アウトラインナビゲーション、文書構造を一目で把握
- **超軽量** — DMG インストーラは10MB未満、ディスク容量をほとんど使用しない

執筆も、協業も、派手な機能も必要なく、ただ**素早く Markdown 文書を閲覧したい**時に、最適な選択です。

---

## 機能

| 機能 | 説明 |
|------|------|
| WebPage レンダリング | cmark-gfm + WebPage（macOS 26 ネイティブ）レンダリング、完全な GFM 拡張構文サポート |
| Mermaid 図表 | フローチャート、シーケンス図、ガントチャート等のローカルレンダリング |
| PlantUML 図表 | PlantUML 構文サポート、SVG として自動レンダリング（ネットワーク必要） |
| 数式 | KaTeX による LaTeX インライン・ブロック数式レンダリング |
| Prism.js シンタックスハイライト | 30+言語のシンタックスハイライト、Prism.js エンジン |
| Quick Look プレビュー | Finder で .md ファイルを選択してスペースキーを押すとプレビュー、アプリ起動不要 |
| 文書全体のコピー | レンダリングモード、ソースモード、Quick Look のいずれからでも文書全体をワンクリックでコピー。設定で一括無効化可能、Quick Look はリッチテキストまたは元の Markdown を選択可能 |
| ライブ編集 | ソースモードで直接編集、Cmd+S で保存、ファイル切り替え時に未保存内容を自動保持 |
| ファイルツリー | フォルダを再帰的に閲覧、キーボードナビゲーション、右クリックで作成/名前変更/削除 |
| アウトラインナビゲーション | 見出し階層を自動抽出、クリックでジャンプ、長文書の効率的な閲覧 |
| オンデマンド読み込み | Mermaid、KaTeX 等のオプションコンポーネントは文書で必要な時だけ読み込み、通常の Markdown 読書がより軽快 |
| 33 テーマ | 20 ダーク + 13 ライト、Markdown Preview Enhanced スタイルテーマ含む、カスタムカラーとコントラスト調整対応 |
| 多言語対応 | 簡体字中国語、繁体字中国語、英語、システムに自動追従 |
| CLI ツール | `mdr` コマンドでターミナルから Markdown ファイルを直接開く |
| コマンドパレット | `Cmd+P` でファイルツリー内のファイルを素早く検索して開く |
| ウィンドウ復元 | 前回の閲覧位置を記憶、再起動時に自動復元 |

---

## ショートカット

| ショートカット | 機能 |
|---------------|------|
| `Cmd+O` | フォルダ / ファイルを開く |
| `Cmd+N` | 新規ファイル |
| `Cmd+S` | ファイルを保存 |
| `Cmd+Option+E` | PDF 書き出し |
| `Cmd+,` | 設定を開く |
| `Cmd+\` | サイドバー切替 |
| `Cmd+Shift+E` | レンダリングモード |
| `Cmd+Shift+R` | ソースモード |
| `Cmd++` | 拡大 |
| `Cmd+-` | 縮小 |
| `Cmd+0` | 実際のサイズ |
| `Cmd+F` | 検索 |
| `Cmd+G` | 次を検索 |
| `Cmd+Shift+G` | 前を検索 |
| `Cmd+Option+F` | 検索と置換 |
| `Cmd+P` | コマンドパレット |

---

## インストール

### ダウンロード

[Releases](https://github.com/davidhoo/MarkdownReader/releases) から最新の DMG をダウンロードし、アプリケーションフォルダにドラッグしてください。

### Homebrew（オプション）

自前の Tap を使って Homebrew でインストールすることもできます：

```bash
brew tap davidhoo/markdownreader
brew install --cask markdownreader

# アップグレード（アプリ自体が自己更新するため、Homebrew に新版を取得させるには --greedy が必要）
brew update
brew upgrade --cask --greedy markdownreader
```

Homebrew はインストールと任意のアップグレードのみを担います。既存の DMG 直接インストールやアプリ内更新はそのまま利用でき、互いに影響しません。

> **公証されていないアプリについて**：MarkdownReader は開発者署名済みですが**公証されていません**（Apple Developer Program 未購入）。インストール方法に関わらず、初回起動時に macOS にブロックされた場合は、アプリケーションで MarkdownReader を **Control** クリックして「**開く**」を選び確認するか、「**システム設定 > プライバシーとセキュリティ**」で「**このまま開く**」をクリックしてください。本リポジトリは Gatekeeper を回避するコマンドを提供しません。

### 動作環境

macOS 26 (Tahoe) 以降。

---

## 公式サイト

[https://davidhoo.github.io/MarkdownReader/](https://davidhoo.github.io/MarkdownReader/)

---

## 謝辞

Markdown Reader は以下のオープンソースプロジェクトなしでは成り立ちません：

- [cmark-gfm](https://github.com/github/cmark-gfm) — GitHub Flavored Markdown パーサー・レンダリングエンジン
- [swift-markdown](https://github.com/apple/swift-markdown) — Apple の Swift Markdown パーサーライブラリ（cmark-gfm ベース）
- [KaTeX](https://katex.org/) — 高速 LaTeX 数式レンダリング
- [Mermaid](https://mermaid.js.org/) — テキストベースの図表生成（フローチャート、シーケンス図、ガントチャート等）
- [Prism.js](https://prismjs.com/) — 軽量コードシンタックスハイライト
- [PlantUML](https://plantuml.com/) — オープンソース UML 図表レンダリング

[linux.do](https://linux.do/) コミュニティのフィードバックとサポートに特別感謝します。

---

MIT License
