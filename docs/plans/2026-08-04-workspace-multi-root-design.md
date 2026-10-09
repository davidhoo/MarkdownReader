# 工作区（Workspace）多目录支持设计

> 设计日期：2026-08-04；实施与验收：2026-08-04 ~ 2026-08-10。
> 文末「实际实施结果」记录落地情况、实施期调整与后续扩展。

## 一、现状分析

- 每窗口一个 `WindowSession`，目录树由 `FileTreeViewModel` 管理，**全链路假设单根目录**：
  - `FileTreeViewModel.nodes` 虽是数组，但 `loadDirectory`/`refreshDirectory`/`rootDirectory`（`nodes.first?.path`）/新建文件默认目录/`isEmptyDirectory` 均为单根逻辑。
  - `AppViewModel.rootDirectory: URL?` 被窗口标题、`sidebarPresentationIdentity`、`WindowSession.openLinkedMarkdownFile`（根目录前缀判断）、`performSaveAs`（保存后刷新树）等多处依赖。
  - `FileSystemWatcher` 只接受单路径（FSEventStream 本身支持路径数组，改造成本低）。
- 打开流程已统一为 `OpenRequest → WindowCoordinator → WindowRoutingEngine`，`ResourceIdentity` 已有 `.file/.directory` kind，新增 `.workspace` kind 即可接入路由与所有权体系。
- 侧边栏 `SidebarView` 直接 `ForEach(fileTreeViewModel.nodes)`，**天然支持多根渲染**；递归 `FileNodeRow`、展开状态 `expandedDirs: Set<URL>` 均按 URL 管理，多根无需结构性改动。
- 持久化只有 UserDefaults（recentItems/lastOpened），无工作区文件；`scripts/Info.plist` 仅注册 Markdown 文档类型。

## 二、总体设计

工作区 = 窗口级概念，每个 `WindowSession` 持有一个工作区状态。单目录打开视为「单根工作区」，行为完全向后兼容。

### 1. 工作区模型（`Models/WorkspaceDocument.swift`）

```swift
struct WorkspaceDocument: Codable, Equatable {
    var version: Int                      // 固定 1
    var folders: [String]                 // 绝对路径，有序
    var expandedDirs: [String]            // 展开的目录路径
    var selectedFile: String?             // 上次选中文件
}
```

- 扩展名 `.mdworkspace`，UTF-8 JSON。
- 非沙箱应用直接存绝对路径；加载时对不存在的目录**跳过并在侧边栏显示缺失提示**（而非整体失败）。
- 会话内工作区状态由 `FileTreeViewModel` 承载：`workspaceIsDirty`（目录增删后相对已保存内容变脏）。

### 2. FileTreeViewModel 多根改造

- `loadWorkspace(folders:restored:)`：逐个 `scanDirectory` 生成根节点，`nodes` = 多根数组；应用 `expandedDirs`（与现存路径求交集）、恢复选中。
- `addFolder(_ url:)`：校验非已有根、非已有根的子目录/父目录（防重叠嵌套）；扫描后追加到 `nodes`，置脏。
- `removeFolder(_ url:)`：移除根节点及其展开状态；若选中文件/当前文档位于该根下，清除选中并释放所有权；置脏。
- `refreshDirectory()` 改为遍历所有根逐个重扫（保留现有防抖/重入保护结构）；`rootDirectory` 语义替换为 `rootDirectories: [URL]`，保留首根供 `createNewFile(in: nil)`、`moveItem` 默认面板目录回退使用。
- `isEmptyDirectory` 改为「所有根均无 Markdown」。

### 3. 多路径文件监控（`Services/FileSystemWatcher.swift`）

- `startWatching(url:)` 扩展为 `startWatching(urls: [URL])`：`pathsToWatch` 传全部根路径给同一个 FSEventStream（原生支持），`watchedURL` 改为 `watchedURLs: Set<URL>`；同集合重复调用仅更新回调。增删目录时重启 stream。

### 4. AppViewModel

- `rootDirectory: URL?` → `rootDirectories: [URL]`（didSet 更新标题）；新增 `isWorkspaceMode: Bool`（根数 > 1 或已关联工作区文件）。
- 窗口标题：已保存工作区显示「Markdown Reader — 名称.mdworkspace」；未保存多根显示「Markdown Reader — Untitled Workspace」；单根保持现状。
- `sidebarPresentationIdentity` 改用全部根路径拼接。
- 全局检索并更新所有 `rootDirectory` 使用点（内链前缀判断改为「任一工作区根之下」、Save As 刷新逻辑改为判断保存路径所属根、`isBlank` 判断等）。

### 5. 保存/加载服务（`Services/WorkspaceFileService.swift`）

- `save(_:to:)` / `load(from:)`；纯逻辑无 UI，可单测。
- 保存成功后：关联文件 URL、复位脏标记、加入 `recentItems`、`recordLastOpened`。

### 6. 类型注册与外部打开

- Info.plist：新增 `UTExportedTypeDeclarations`（`com.markdownreader.workspace`，conforms to `public.json`，扩展名 `mdworkspace`）与对应 `CFBundleDocumentTypes`（Role = Editor）。
- `ResourceIdentity.Kind` 新增 `.workspace`；`ResourceIdentityService` 识别 `.mdworkspace` 扩展名。
- 冷/热启动 `openFiles` 走统一路由；所有权按「工作区文件 + 其全部文件夹」一并 claim（防止另一窗口重复打开同一目录）。
- 打开工作区的路由决策复用现有引擎：空白窗口复用（`openInSession`），否则新建窗口（`createWindow` + pending resource）。

### 7. WindowSession 命令

- `openWorkspace(_ url:)`：加载文档 → 过滤缺失目录 → claim 全部文件夹 → 多根加载并恢复展开/选中。
- `addFolderToWorkspace()`：窗口级 NSOpenPanel（仅目录）→ `addFolder` → 保证 Sidebar 可见。
- `removeFolderFromWorkspace(_ url:)`：转发至 VM，并释放该根目录所有权。
- `saveWorkspace()` / `saveWorkspaceAs()`：未关联文件走 Save As（默认名取首个根目录名 + `.mdworkspace`，窗口级 sheet）；已关联且未脏则 no-op。
- **关闭确认**：`prepareForClose()` 增加分支——工作区脏时返回新增 `CloseDecision.needsWorkspaceDecision`；终止协调器新增「保存工作区 / 不保存 / 取消」对话框（沿用现有 NSAlert 模式与 L10n），与脏 Untitled 决策串行处理。

### 8. UI 与菜单

- `SidebarView`：根目录行右键菜单追加「从工作区移除文件夹」；侧边栏顶部工具条增加「添加文件夹」按钮（`folder.badge.plus`）。
- `MarkdownReaderCommands`（File 菜单）：新增「添加文件夹到工作区…」「保存工作区」「工作区另存为…」；Cmd+O 面板允许选择 `.mdworkspace` 文件。
- `CommandPaletteViewModel`：文件搜索范围从单根扩展为遍历全部工作区根，多根结果带根名前缀区分。
- 本地化：`LocalizationService` 新增 12 个 L10n 键（三语）。

## 三、测试计划

现有套件共 20 个文件约 137 个用例。策略：**实施前先跑一次 `swift test` 确立绿色基线**；每个实施阶段结束时全量回归，任何既有测试失败一律视为 regression 阻塞项。

### 3.1 既有测试 → 改动区域的回归映射（必须原样通过）

| 既有测试套件 | 保护的既有行为 |
|---|---|
| `WindowRoutingEngineTests` / `OpenRequestRoutingTests` | 路由决策、空白窗口复用、drain 队列语义 |
| `DirectoryWindowNavigationTests` / `FileOwnershipSelectionTests` | 目录内文件切换事务、所有权释放/保留 |
| `OpenDirectorySidebarTests` | Sidebar 显隐/宽度、`sidebarPresentationIdentity` 重建语义 |
| `MultiWindowRegressionTests` | 内链文件跨窗口激活 owner |
| `NewFileAndSaveFlowTests` | Save As 后刷新树与所有权迁移 |
| `UnsavedCloseCoordinatorTests` / `ApplicationTerminationCoordinatorTests` | 脏 Untitled 关闭确认流程 |
| `ResourceIdentityServiceTests` | identity 解析规则 |
| `WindowSessionTests` / `WindowCoordinatorTests` / `WindowLifecycleRegistryTests` | session 空白判定、注册注销、所有权批量释放 |
| `MenuLocalizationTests` | 主菜单本地化 |

### 3.2 补齐盲区：先给现有行为补「特征测试」，再动手重构

- `FileTreeViewModelBaseTests`：单根加载/刷新/新建/空判定/键盘导航。
- `FileSystemWatcherTests`：单路径触发、防抖、stopWatching 无残余；多路径任一根触发、同集合不重启。
- `AppViewModelTitleTests`：单目录/单文件/Untitled/工作区标题。
- `CommandPaletteViewModelTests`：单根搜索、跨根搜索与根名前缀。

### 3.3 新功能测试

- `WorkspaceFileServiceTests`、`FileTreeViewModelWorkspaceTests`、`WorkspaceRoutingTests`、`WindowSessionWorkspaceTests`、`UnsavedWorkspaceCloseTests`、`WorkspaceLocalizationTests`。

### 3.4 验收标准

- 3.1 全部既有用例零断言修改通过（构造代码适配除外）。
- 3.2 / 3.3 新增用例全部通过；`swift build -c release` 无警告新增。

## 四、实施顺序

0. 基线：`swift test` 全绿；补齐 3.2 特征测试并再次全绿。
1. 模型与多根树：`WorkspaceDocument`、`FileTreeViewModel` 多根、`FileSystemWatcher` 多路径、`AppViewModel.rootDirectories`（含全部使用点迁移）。
2. 持久化与路由：`WorkspaceFileService`、Info.plist UTType、`ResourceIdentity.workspace`、打开链路。
3. 交互：添加/移除文件夹、保存/另存为、菜单与侧边栏按钮、L10n、关闭确认。
4. 收尾：补齐 3.3 新功能测试，release 构建全绿。

## 五、明确不做（范围外）

- 不解析/写入 VS Code `.code-workspace` 文件。
- 不自动持久化未保存工作区（关闭时询问即可）。
- 不支持每窗口多标签页/多文档；工作区内仍是单文档浏览。
- 不记录滚动位置（仅恢复展开状态 + 选中文件）。

---

# 实际实施结果（2026-08-10 追加）

## 验收结论

- **测试**：`swift test` 220 用例全绿（137 既有 + 83 新增）；既有 20 个测试文件**零改动**（`git diff` 为空），满足 3.1 验收。
- **构建**：`swift build -c release` 无新增警告（仅余 2 个改造前既有的 actor 隔离警告）；`./build-app.sh --release --sign` 打包 + ad-hoc 签名通过，`plutil -lint` Info.plist OK。
- **人工验证**：工作区打开/恢复、增删目录、保存/另存为、关闭确认、拖拽添加、视觉提示等均经真机验证通过。

## 实施期对设计的调整

1. **`rootDirectory` 保留为兼容计算属性**：`AppViewModel` 以 `rootDirectories: [URL]` 为源，`rootDirectory` 提供 getter/setter 兼容层，降低迁移面。
2. **工作区文件 URL 单一数据源**：设计原稿让 `FileTreeViewModel` 持有 `workspaceFileURL`，实施中改为 `AppViewModel.workspaceFileURL` 单一持有（窗口标题同源），VM 只维护脏标记。
3. **视图/会话驱动竞态防护**：`DirectoryChangeModifier` 增加一次性 `suppressNextDirectoryChangeReaction` 标记与 `matchesActiveRoots` 去重，避免 session 直接加载与视图 onChange 重载互相覆盖选中状态。
4. **环境路径归一**：测试环境 `contentsOfDirectory` 固定返回 `/private/var` 前缀且 `resolvingSymlinksInPath()` 不归一化；测试统一做路径归一，代码注释固化。
5. **URL 相等性不可靠**：不同来源构造的目录 URL 内部表示可能不同；恢复展开/选中状态一律按**路径字符串**匹配，并映射到树内节点 URL（保证侧边栏高亮等比对一致）。

## 验收后扩展（2026-08-04 之后）

1. **拖拽目录到侧边栏添加文件夹**：
   - 窗口级 `WindowDropOverlayView`（AppKit，覆盖全窗）优先于 SwiftUI 拖放目标，故分流在 overlay 层按落点完成（`dropIsInsideSidebar` 横向坐标判断）：侧边栏内目录 → `addDroppedFolder`（复用重复/嵌套校验与所有权声明），文件仍走统一路由；其余区域保持原「打开」行为。空白窗口拖入目录等价于打开目录。
   - `performAddFolder` 的错误弹窗抽为可注入闭包（`addFolderErrorPresenterForTesting`），使 headless 测试可验证冲突分支。
2. **拖拽视觉提示分区**：`AppViewModel.isSidebarDropTargeted` 随悬停位置实时更新（`draggingEntered/Updated`）；悬停侧边栏显示虚线框 + 「添加文件夹到工作区…」标签，内容区实线高亮让位，二者互斥。
3. **根目录行显示绝对路径**：工作区模式下顶层根行名称后内联弱色绝对路径（`truncationMode(.middle)`，名称 `layoutPriority` 优先），单目录模式不显示。
4. **关闭已关联工作区选「保存」直接覆写原文件**：`resolveWorkspaceChanges` 先检查 `workspaceFileURL`，已关联直接 `performWorkspaceSave(to: 原文件)`，未关联才弹另存为面板（与菜单「保存工作区」语义一致）。回归测试 `testAssociatedWorkspaceSaveOverwritesOriginalFileWithoutPanel` 锁定。

## 交付文件清单

新增：

- `Sources/MarkdownReader/Models/WorkspaceDocument.swift`
- `Sources/MarkdownReader/Services/WorkspaceFileService.swift`
- 测试：`FileTreeViewModelBaseTests`、`FileSystemWatcherTests`、`AppViewModelTitleTests`、`CommandPaletteViewModelTests`、`FileTreeViewModelWorkspaceTests`、`WorkspaceFileServiceTests`、`WorkspaceRoutingTests`、`WindowSessionWorkspaceTests`、`UnsavedWorkspaceCloseTests`、`WorkspaceLocalizationTests`

修改：

- `FileTreeViewModel`（多根加载/增删/跨根刷新/脏标记）、`FileSystemWatcher`（多路径）、`AppViewModel`（rootDirectories/标题/拖拽分区状态）
- `ResourceIdentity` / `ResourceIdentityService` / `WindowCoordinator` / `WindowSceneHost`（workspace 路由与所有权）
- `WindowSession`（openWorkspace/增删/保存/关闭决策/拖拽入口）、`ApplicationTerminationCoordinator` / `UnsavedDocumentCloseCoordinator` / `AppKitUnsavedCloseInteraction`（工作区关闭确认）
- `WindowLifecycleBridge`（拖拽分流与分区高亮）、`SidebarView` / `FileRowView` / `DetailView`（UI）、`MarkdownReaderCommands` / `WindowCommand` / `WindowCommandTarget`（菜单命令）
- `CommandPaletteViewModel`（跨根搜索）、`LocalizationService`（12 键三语）、`scripts/Info.plist`（UTType 注册）
