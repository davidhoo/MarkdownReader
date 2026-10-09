import Foundation
import AppKit
import SwiftUI

/// 应用级窗口协调器。
///
/// 维护会话注册表和资源所有权注册表，将无副作用的路由判断委托给 `WindowRoutingEngine`。
/// 所有写入都在 `@MainActor` 完成，保证所有权事务原子性。
///
/// 引用关系（见设计文档 §7.1）：
/// - App 持有 Coordinator。
/// - Coordinator 在窗口注册期间强持有 `WindowSession`（通过 sessions 字典）。
/// - `WindowSession` 弱引用 Coordinator，避免环。
/// - Coordinator 只弱持有 `NSWindow`。
@MainActor
@Observable
final class WindowCoordinator {

    // MARK: - 注册表

    /// 已注册会话：windowID → session。强持有真实会话；测试占位时不写入此字典。
    private(set) var sessions: [WindowID: WindowSession] = [:]

    /// 已注册的 windowID 集合（含测试占位，用于区分「注册」与「未注册」）。
    private var registeredIDs: Set<WindowID> = []

    /// 资源所有权：identity → windowID。
    private(set) var resourceOwners: [ResourceIdentity: WindowID] = [:]

    /// 每个窗口持有的资源集合（反向索引，便于注销时批量释放）。
    private var ownedResources: [WindowID: Set<ResourceIdentity>] = [:]

    /// 测试用 registerSession 的空白标记。真实 session 通过 WindowSession.isBlank 计算。
    private var blankFlags: [WindowID: Bool] = [:]

    /// 待加载资源：windowID → resource。用于新窗口创建后取走初始资源。
    private var pendingResources: [WindowID: ResourceIdentity] = [:]

    /// 弱持有 NSWindow，用于激活/前置。
    private var windows: [WindowID: WeakWindow] = [:]

    /// 最后活动窗口，用于 Dock 重开前置和单窗口恢复。
    /// 由 MRU 列表（`mruWindowIDs`）的末尾派生，确保关闭当前窗口后回退到最近活动的窗口。
    private(set) var lastActiveWindowID: WindowID? {
        get { mruWindowIDs.last }
        set {
            if let id = newValue {
                recordActive(windowID: id)
            } else {
                mruWindowIDs.removeAll()
            }
        }
    }

    /// 窗口活动顺序（MRU，最久未用在前、最近活动在末尾）。
    /// Task 5：替代 `registeredIDs.first` 的非确定性回退，提供确定性的「上一个活动窗口」。
    private var mruWindowIDs: [WindowID] = []

    // MARK: - 打开请求队列（Task 8）

    /// 待处理的打开请求。冷启动 Coordinator 尚未 attach 窗口时，请求在此暂存。
    private var pendingRequests: [OpenRequest] = []

    /// 当前待处理请求数量。
    var pendingRequestCount: Int { pendingRequests.count }

    // MARK: - 依赖

    private let identityService: ResourceIdentityService
    private let routingEngine: WindowRoutingEngine
    private var openWindowAction: OpenWindowAction?

    /// 回归修复：暴露给 WindowSession 做目录内导航的 identity 解析（与所有权判断同源）。
    var sharedIdentityService: ResourceIdentityService { identityService }

    /// 测试用：注入窗口创建闭包。生产路径走 `OpenWindowAction`。
    /// 仅当 `openWindowAction == nil` 时生效，使无真实 action 的测试也能完成 createWindow 决策。
    var windowCreationClosureForTesting: ((WindowID) -> Void)?

    /// 测试用：暴露 pending resource 表，便于断言「资源已预存给新窗口」。
    var pendingResourcesForTesting: [WindowID: ResourceIdentity] {
        pendingResources
    }

    init(
        identityService: ResourceIdentityService = ResourceIdentityService(),
        routingEngine: WindowRoutingEngine = WindowRoutingEngine()
    ) {
        self.identityService = identityService
        self.routingEngine = routingEngine
    }

    // MARK: - 注册表查询

    var sessionCount: Int { registeredIDs.count }

    /// id 是否已注册（含真实 session 或测试占位）。
    func isRegistered(_ id: WindowID) -> Bool { registeredIDs.contains(id) }

    func owner(of identity: ResourceIdentity) -> WindowID? { resourceOwners[identity] }

    func ownerWindowID(ofFile url: URL) throws -> WindowID? {
        let identity = try identityService.identity(for: url, kind: .file)
        return resourceOwners[identity]
    }

    /// 文件 URL 是否由「本 windowID 之外」的窗口持有（Task 9 目录树标记）。
    /// 不可识别身份（目录等）始终返回 false。
    func isFileOwnedByAnotherWindow(_ url: URL, besides windowID: WindowID) -> Bool {
        guard let identity = try? identityService.identity(for: url, kind: .file) else {
            return false
        }
        if let owner = resourceOwners[identity], owner != windowID {
            return true
        }
        return false
    }

    /// 回归修复：文件是否由指定 windowID 自身持有（目录内导航幂等判断）。
    func isFileOwnedBySelf(_ url: URL, owner windowID: WindowID) -> Bool {
        guard let identity = try? identityService.identity(for: url, kind: .file) else {
            return false
        }
        return resourceOwners[identity] == windowID
    }

    /// 回归修复：释放某窗口对指定文件 URL 的所有权（目录内导航切换旧文件时调用）。
    /// 不影响该窗口的根目录所有权。不可识别身份或非本窗口持有时为 no-op。
    func releaseFileOwnership(_ url: URL, for windowID: WindowID) {
        guard let identity = try? identityService.identity(for: url, kind: .file) else { return }
        release(identity, for: windowID)
    }

    /// 当前是否存在任何空白会话。
    var hasBlankSession: Bool {
        registeredIDs.contains { id in
            sessions[id]?.isBlank ?? (blankFlags[id] ?? false)
        }
    }

    /// 当前是否已注册至少一个会话。
    var hasRegisteredSession: Bool { !registeredIDs.isEmpty }

    // MARK: - OpenWindowAction 安装

    /// 安装 SwiftUI 的 `OpenWindowAction`，使 Coordinator 能创建新窗口。
    /// 幂等：可多次调用，只保留最新 action。
    /// Task 2：安装后立即尝试 drain（pending 请求可能已在等待 action 就绪）。
    func install(openWindowAction: OpenWindowAction) {
        self.openWindowAction = openWindowAction
        drainIfReady()
    }

    var isReady: Bool { openWindowAction != nil }

    // MARK: - 会话注册

    /// 注册会话。Coordinator 强持有 session。
    /// Task 2：注册后尝试 drain（pending 请求可能在等待首个 session 就绪）。
    func register(session: WindowSession) {
        sessions[session.id] = session
        registeredIDs.insert(session.id)
        if ownedResources[session.id] == nil {
            ownedResources[session.id] = []
        }
        drainIfReady()
    }

    /// 注册会话并关联其 NSWindow（Task 6 生命周期桥接入口）。
    /// 由 WindowSceneHost 在窗口挂载时调用；session.window 通过 bridge 回填。
    func register(session: WindowSession, window: NSWindow?) {
        register(session: session)
        if let window {
            attach(window: window, to: session.id)
        }
    }

    /// 注册会话的轻量重载（测试用，不依赖真实 session 对象，仅维护路由快照）。
    func registerSession(id: WindowID, isBlank: Bool) {
        if ownedResources[id] == nil { ownedResources[id] = [] }
        registeredIDs.insert(id)
        blankFlags[id] = isBlank
    }

    /// 关联 NSWindow 到 windowID（弱引用）。
    func attach(window: NSWindow, to windowID: WindowID) {
        windows[windowID] = WeakWindow(value: window)
    }

    /// 注销会话：释放 session、窗口引用和所有资源所有权。
    func unregister(windowID: WindowID) {
        // 释放该窗口持有的全部资源所有权
        if let resources = ownedResources.removeValue(forKey: windowID) {
            for resource in resources {
                if resourceOwners[resource] == windowID {
                    resourceOwners.removeValue(forKey: resource)
                }
            }
        }
        pendingResources.removeValue(forKey: windowID)
        windows.removeValue(forKey: windowID)
        blankFlags.removeValue(forKey: windowID)
        registeredIDs.remove(windowID)
        sessions.removeValue(forKey: windowID)
        // Task 5：从 MRU 移除。lastActiveWindowID 由 MRU 末尾派生——
        // 若关闭的正是当前活动窗口，回退到 MRU 中最近活动且仍注册的窗口（末尾）；
        // 没有窗口时 lastActiveWindowID 自然为 nil。
        mruWindowIDs.removeAll { $0 == windowID }
    }

    // MARK: - 所有权事务

    /// 声明某窗口持有某资源。
    /// - Throws: 资源已被其他窗口持有时抛 `ownershipConflict`。
    func claim(_ resource: ResourceIdentity, for windowID: WindowID) throws {
        if let existing = resourceOwners[resource], existing != windowID {
            throw OpenRoutingError.ownershipConflict(resource.canonicalURL, owner: existing)
        }
        resourceOwners[resource] = windowID
        ownedResources[windowID, default: []].insert(resource)
    }

    /// 释放某窗口对某资源的所有权。
    func release(_ resource: ResourceIdentity, for windowID: WindowID) {
        guard resourceOwners[resource] == windowID else { return }
        resourceOwners.removeValue(forKey: resource)
        ownedResources[windowID]?.remove(resource)
    }

    /// 原子迁移所有权：旧 URL → 新 URL（用于另存为/重命名/移动）。
    /// - 先预检目标是否已被其他窗口持有。
    /// - 旧所有权必须属于本窗口。
    /// - 任一步失败不得修改原状态。
    func migrateOwnership(from oldURL: URL, to newURL: URL, for windowID: WindowID) throws {
        let oldIdentity = try identityService.identity(for: oldURL, kind: .file)
        let newIdentity = try identityService.identity(for: newURL, kind: .file)

        // 旧 URL 必须由本窗口持有
        guard resourceOwners[oldIdentity] == windowID else {
            // 旧 URL 不属本窗口（如 Untitled 首次 Save As 时旧 URL 从未注册）：
            // 不迁移，但需为本窗口声明新 URL 所有权。仍要先检查新目标是否被他人占用。
            if let other = resourceOwners[newIdentity], other != windowID {
                throw OpenRoutingError.ownershipMigrationConflict(newURL, owner: other)
            }
            try claim(newIdentity, for: windowID)
            return
        }

        // 新目标已被其他窗口持有 → 冲突，不修改任何状态
        if let other = resourceOwners[newIdentity], other != windowID {
            throw OpenRoutingError.ownershipMigrationConflict(newURL, owner: other)
        }

        // 执行迁移
        resourceOwners.removeValue(forKey: oldIdentity)
        ownedResources[windowID]?.remove(oldIdentity)
        resourceOwners[newIdentity] = windowID
        ownedResources[windowID, default: []].insert(newIdentity)
    }

    // MARK: - 待加载资源

    /// 为待创建窗口预存初始资源。
    func storePending(resource: ResourceIdentity, for windowID: WindowID) {
        pendingResources[windowID] = resource
    }

    /// 取走并清除该窗口的待加载资源。
    func consumePendingResource(for windowID: WindowID) -> ResourceIdentity? {
        pendingResources.removeValue(forKey: windowID)
    }

    // MARK: - 路由

    /// 目录树/命令面板点击文件前的路由判断。
    func routeFileSelection(_ url: URL, from windowID: WindowID) -> RouteDecision {
        let resource: ResourceIdentity
        do {
            resource = try identityService.identity(for: url, kind: .file)
        } catch {
            return .reject(.unsupportedType(url))
        }
        let state = routingSnapshot()
        return routingEngine.decision(
            for: resource,
            preferredWindowID: windowID,
            state: state
        )
    }

    /// 构造路由引擎所需的状态快照。
    func routingSnapshot() -> WindowRoutingState {
        var state = WindowRoutingState()
        for id in registeredIDs {
            let blank = sessions[id]?.isBlank ?? (blankFlags[id] ?? false)
            state.sessions[id] = SessionRoutingSnapshot(id: id, isBlank: blank)
        }
        state.owners = resourceOwners
        return state
    }

    // MARK: - 窗口创建与激活

    /// 创建一个空白窗口。
    func openBlankWindow() {
        let id = WindowID()
        createWindow(for: id)
    }

    /// 为指定资源创建窗口，并预存初始资源供新窗口消费。
    func openResourceInNewWindow(_ resource: ResourceIdentity) {
        let id = WindowID()
        storePending(resource: resource, for: id)
        createWindow(for: id)
    }

    /// 实际触发窗口创建：优先 SwiftUI `OpenWindowAction`；测试环境无 action 时走注入闭包。
    private func createWindow(for id: WindowID) {
        if openWindowAction != nil {
            openWindowAction?(id: WindowSceneID.document, value: id)
        } else {
            windowCreationClosureForTesting?(id)
        }
    }

    /// 激活某窗口：解最小化、显示、置前、激活应用。
    func activate(windowID: WindowID) {
        lastActiveWindowID = windowID
        guard let window = windows[windowID]?.value else {
            // 窗口引用失效：若已安装 OpenWindowAction 则通过它重建/前置。
            openWindowAction?(id: WindowSceneID.document, value: windowID)
            // 测试/headless 环境下 NSApp 可能为 nil，安全激活而非强制解包。
            NSApp?.activate(ignoringOtherApps: true)
            return
        }
        window.deminiaturize(nil)
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// 记录最后活动窗口（Task 5：维护 MRU 顺序）。
    /// 将 windowID 移到 MRU 末尾（最近活动），lastActiveWindowID 由末尾派生。
    func recordActive(windowID: WindowID) {
        mruWindowIDs.removeAll { $0 == windowID }
        mruWindowIDs.append(windowID)
    }

    /// 所有已注册且仍可见的窗口（用于 Dock 重开判断和 Window 菜单）。
    func visibleWindowIDs() -> [WindowID] {
        registeredIDs.filter { id in
            windows[id]?.value?.isVisible == true
        }
    }

    // MARK: - 打开请求路由（Task 2：Coordinator 独立管理队列与 readiness）

    /// drain 重入保护：`handleOpenRequest` 内部可能经 `openWindowAction` 间接触发新的 `enqueue`
    /// （如窗口挂载后立即 enqueue），重入时新请求留在队列等下一轮，避免递归 drain。
    private var isDraining = false

    /// 将打开请求入队（Task 2）。
    ///
    /// 统一约束：**请求始终先入队**，再按 readiness drain。禁止根据 `hasRegisteredSession`
    /// 直接绕过队列调用 `handleOpenRequest`——那样会让「ready 但 action 未安装」时请求被
    /// 直接消费却无法创建窗口（pending resource 无人认领）。
    ///
    /// - 入队 → 若 ready（`openWindowAction` 已安装）则 `drainIfReady()`；否则保留等待。
    func enqueue(_ request: OpenRequest) {
        pendingRequests.append(request)
        drainIfReady()
    }

    /// 幂等的就绪 drain（Task 2）。
    ///
    /// 由 `enqueue`、`install(openWindowAction:)`、`register(session:)` 触发。
    /// 约束：
    /// - `openWindowAction == nil` 时直接返回，**不清除任何请求**。
    /// - 重入保护：drain 期间新入队的请求留到下一轮（见 `performDrain` 的收尾重试）。
    /// - external 请求先于非 external（如 restore），同优先级 FIFO。
    /// - 每个请求**进入路由执行阶段后**才从队列移除（先按顺序取出再执行，执行失败也不回填，
    ///   因为 missing URL 等已在路由层 reject，不阻塞后续）。
    func drainIfReady() {
        _ = performDrain(returnsProcessed: false)
    }

    /// 排空所有待处理请求，返回实际处理的请求列表（Task 2）。
    ///
    /// 语义：
    /// - `openWindowAction == nil`（且无测试闭包）时不删除任何请求，返回空。
    /// - 返回本轮实际处理（进入路由执行阶段）的请求列表。
    @discardableResult
    func drainPendingRequests() -> [OpenRequest] {
        performDrain(returnsProcessed: true) ?? []
    }

    /// drain 的唯一实现（Task 2 收敛：消除 `drainIfReady` / `drainPendingRequests` 重复逻辑）。
    ///
    /// - Parameters:
    ///   - returnsProcessed: true 时返回本轮处理的请求列表；false 时返回 nil（`drainIfReady` 不关心）。
    /// - Returns: 处理的请求列表（仅 `returnsProcessed == true` 时有意义），或 nil。
    ///
    /// 重入语义：处理过程中清空队列再遍历 toProcess。若 drain 期间（`isDraining == true`）有新请求
    /// 经 `enqueue` 入队，那次 `enqueue` 调的 `drainIfReady` 会被重入闸挡住直接返回，新请求留在队列。
    /// 因此 `defer` 复位 `isDraining` 后**补一次收尾 drain**——若队列此时非空则再处理一轮，否则直接返回。
    /// 收尾 drain 不会无限递归：若再次无新请求入队，下一轮 `performDrain` 在「队列为空」闸处返回。
    @discardableResult
    private func performDrain(returnsProcessed: Bool) -> [OpenRequest]? {
        // readiness：action 未安装且无测试闭包时根本无法创建新窗口，drain 会丢失请求 → 保留等待。
        guard openWindowAction != nil || windowCreationClosureForTesting != nil else {
            return returnsProcessed ? [] : nil
        }
        // 重入：正在 drain 时新入队的请求留到下一轮（由 defer 后收尾 drain 接管）。
        guard !isDraining else { return returnsProcessed ? [] : nil }
        // 无待处理请求：直接返回。
        guard !pendingRequests.isEmpty else { return returnsProcessed ? [] : nil }

        isDraining = true
        defer {
            isDraining = false
            // 收尾：drain 期间若有新请求入队（被重入闸挡住），此处补一轮。队列为空时下一轮立即返回。
            if !pendingRequests.isEmpty {
                _ = performDrain(returnsProcessed: false)
            }
        }

        // 排序：external 优先，同优先级保持入队顺序（FIFO）。stable 排序保证稳定性。
        let sorted = pendingRequests.sorted { a, b in
            if a.source == .external && b.source != .external { return true }
            if a.source != .external && b.source == .external { return false }
            return false
        }

        // 暂存本轮要处理的请求并清空队列；drain 期间新入队的请求会进入被清空后的队列，
        // 由 defer 收尾 drain 接管。
        let toProcess = sorted
        pendingRequests.removeAll()

        for request in toProcess {
            handleOpenRequest(request)
        }
        return returnsProcessed ? toProcess : nil
    }

    /// 路由后的打开项：把 URL 与其决策关联起来（Task 4）。
    struct RoutedOpenItem: Equatable {
        let url: URL
        let decision: RouteDecision
    }

    /// 对一批 URL 做路由决策（不执行副作用），返回 `RoutedOpenItem`（Task 4）。
    ///
    /// 约束：
    /// - 每个 URL **只做一次**存在性、类型和 identity 解析（旧实现遍历两次）。
    /// - missing → `.reject(.resourceMissing)`；identity 构建失败 → `.reject(.unsupportedType)`。
    /// - 同一批请求中的**重复 identity 只决策一次**（重复项复用首项决策，避免重复副作用）。
    /// - 保留原始有效资源顺序（按 urls 输入顺序）。
    /// - 批量决策复用 `routingEngine.decisions(for:)`，不再复制 working state 更新逻辑。
    ///
    /// 不能把 decisions 整体替换成 `decisions(for:)` 再按下标回填——批量 API 会去重，
    /// 返回的 decisions 数组短于 urls，下标映射错位。这里先解析出「去重的有效 identity 顺序」，
    /// 用批量 API 拿到它们的决策，再按原始 url 顺序回填（重复 identity 复用同一决策）。
    func routeOpenRequest(urls: [URL], preferredWindowID: WindowID?) -> [RoutedOpenItem] {
        // 单次遍历：解析每个 url 的存在性/类型/identity，同时收集去重的有效 identity 顺序。
        var dedupedIdentities: [ResourceIdentity] = []
        var dedupedSet = Set<ResourceIdentity>()
        // 每个 url 按顺序记录解析结果：要么 identity，要么 reject。
        var perURL: [PerURLRouting] = []

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                perURL.append(.reject(.resourceMissing(url), url))
                continue
            }
            let kind: ResourceIdentity.Kind
            if isDir.boolValue {
                kind = .directory
            } else if WorkspaceDocument.isWorkspaceFile(url) {
                kind = .workspace
            } else {
                kind = .file
            }
            guard let identity = try? identityService.identity(for: url, kind: kind) else {
                perURL.append(.reject(.unsupportedType(url), url))
                continue
            }
            // 去重：仅首次出现的 identity 进入批量决策；后续重复 url 复用其决策。
            if dedupedSet.insert(identity).inserted {
                dedupedIdentities.append(identity)
            }
            perURL.append(.identity(identity, url))
        }

        // 批量决策（复用 routingEngine，内部维护 working state 与 blankConsumed）。
        let decisions = routingEngine.decisions(
            for: dedupedIdentities,
            preferredWindowID: preferredWindowID,
            state: routingSnapshot()
        )
        // identity → 决策 的映射（去重后一一对应）。
        var decisionByIdentity: [ResourceIdentity: RouteDecision] = [:]
        for (identity, decision) in zip(dedupedIdentities, decisions) {
            decisionByIdentity[identity] = decision
        }

        // 回填：按原始 url 顺序输出 RoutedOpenItem，重复 identity 复用同一决策。
        var items: [RoutedOpenItem] = []
        items.reserveCapacity(perURL.count)
        for entry in perURL {
            switch entry {
            case .identity(let identity, let url):
                let decision = decisionByIdentity[identity] ?? .reject(.unsupportedType(url))
                items.append(RoutedOpenItem(url: url, decision: decision))
            case .reject(let error, let url):
                items.append(RoutedOpenItem(url: url, decision: .reject(error)))
            }
        }
        return items
    }

    /// 单个 URL 的路由解析中间结果（内部用）。
    private enum PerURLRouting {
        case identity(ResourceIdentity, URL)
        case reject(OpenRoutingError, URL)
    }

    /// 执行打开请求：路由 + 副作用（激活/创建窗口）（Task 4）。
    /// 直接遍历 `RoutedOpenItem`，不再用 decision 下标反查 `request.urls[index]`。
    ///
    /// 重复 identity 跳过（Task 4 收尾）：同一请求中重复 URL 复用首项决策，但只对首个执行
    /// openInSession/createWindow 副作用，后续重复项直接激活 owner，避免重复文件加载。
    private func handleOpenRequest(_ request: OpenRequest) {
        guard !request.urls.isEmpty else { return }

        let items = routeOpenRequest(
            urls: request.urls,
            preferredWindowID: request.preferredWindowID
        )

        var executedIdentities = Set<ResourceIdentity>()

        for item in items {
            let url = item.url
            switch item.decision {
            case .openInSession(let windowID, let resource):
                // 重复 identity：首项已执行过 open 副作用，后续只激活 owner，不再重复加载
                if !executedIdentities.insert(resource).inserted {
                    activate(windowID: windowID)
                    continue
                }
                // 复用已有窗口：在 session 中打开资源（文件或目录）。
                // 必须同步 activate：冷启动 Finder 双击时，SwiftUI 会创建不可见默认窗口；
                // 若只加载文档不前置窗口，进程存活但窗口数仍为 0，用户感知为“打不开文件”。
                if let session = sessions[windowID] {
                    session.markOpenStarted()
                    try? claim(resource, for: windowID)
                    activate(windowID: windowID)
                    Task { @MainActor in
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                        if isDir.boolValue {
                            await session.openDirectory(url)
                        } else if WorkspaceDocument.isWorkspaceFile(url) {
                            await session.openWorkspace(url)
                        } else {
                            await session.openFile(url)
                        }
                        session.clearBlankOverride()
                    }
                } else {
                    // 仅有测试占位 session（无真实 WindowSession）时，仍需激活以更新 MRU。
                    activate(windowID: windowID)
                }

            case .createWindow(let newID, let resource):
                // 重复 identity：首项已建窗，后续激活该新窗口（虽然尚未 attach，激活会触发 openWindowAction 前置）
                if !executedIdentities.insert(resource).inserted {
                    activate(windowID: newID)
                    continue
                }
                // 创建新窗口：预存资源，由 WindowSceneHost 消费
                storePending(resource: resource, for: newID)
                createWindow(for: newID)

            case .activateOwner(let ownerID, _):
                activate(windowID: ownerID)

            case .reject:
                // 文件缺失或不支持：记录日志，不阻塞后续
                break
            }
        }
    }
}

// MARK: - WeakWindow

/// 弱引用 NSWindow 的包装，避免 Coordinator 与窗口形成引用环。
struct WeakWindow {
    weak var value: NSWindow?
    init(value: NSWindow?) { self.value = value }
}
