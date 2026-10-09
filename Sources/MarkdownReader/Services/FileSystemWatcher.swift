import Foundation

/// 文件系统监控服务，使用 FSEventStream 实时监控目录变化
/// 当目录中发生文件创建、删除、重命名等变化时，通过回调通知
/// 所有回调均在主线程执行，确保与 @MainActor 安全交互
final class FileSystemWatcher: @unchecked Sendable {

    /// 变化回调
    private var onChange: (@Sendable () -> Void)?

    /// FSEventStream 引用
    private var stream: FSEventStreamRef?

    /// 防抖定时器
    private var debounceWorkItem: DispatchWorkItem?

    /// 防抖间隔（秒）
    private let debounceInterval: TimeInterval

    /// 当前正在监控的目录 URL 集合（工作区多根）
    private(set) var watchedURLs: Set<URL> = []

    /// 兼容单根语义：当前监控集合的首个目录。
    var watchedURL: URL? { watchedURLs.first }

    /// 是否已失效（防止 stopWatching 后残余回调访问实例）
    private var isInvalidated = false

    init(debounceInterval: TimeInterval = 0.3) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        stopWatching()
    }

    /// 开始监控指定目录（递归监控所有子目录）
    /// - Parameters:
    ///   - url: 要监控的目录 URL
    ///   - onChange: 检测到变化时的回调（在主线程执行）
    func startWatching(url: URL, onChange: @escaping @Sendable () -> Void) {
        startWatching(urls: [url], onChange: onChange)
    }

    /// 开始监控一组目录（工作区多根；FSEventStream 原生支持多路径）。
    /// - Parameters:
    ///   - urls: 要监控的目录 URL 列表
    ///   - onChange: 检测到变化时的回调（在主线程执行）
    func startWatching(urls: [URL], onChange: @escaping @Sendable () -> Void) {
        let newSet = Set(urls)
        // 如果已经在监控同一组目录，只更新回调
        if watchedURLs == newSet {
            self.onChange = onChange
            return
        }

        stopWatching()

        self.onChange = onChange
        self.watchedURLs = newSet
        self.isInvalidated = false

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = newSet.map(\.path).sorted() as CFArray

        // kFSEventStreamCreateFlagFileEvents: 接收文件级事件（创建、删除、重命名等）
        // kFSEventStreamCreateFlagUseCFTypes: 事件路径使用 CF 类型
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds in
                guard let info = clientCallBackInfo else { return }
                let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
                // 防止 stopWatching 后残余回调访问已失效的实例
                guard !watcher.isInvalidated else { return }
                watcher.handleEvent()
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            self.watchedURLs = []
            return
        }

        self.stream = stream

        // 在主队列上调度，确保回调在主线程执行
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    /// 停止监控
    func stopWatching() {
        // 先标记失效，防止 FSEventStreamStop 后的残余回调访问实例
        isInvalidated = true

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        onChange = nil
        watchedURLs = []
    }

    /// 处理文件系统事件（防抖：连续变化合并为一次刷新）
    private func handleEvent() {
        // 取消之前的防抖定时器
        debounceWorkItem?.cancel()

        // 创建新的防抖定时器，在 debounceInterval 后执行回调
        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
