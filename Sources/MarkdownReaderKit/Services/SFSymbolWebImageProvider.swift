import AppKit
import Foundation
import MarkdownReaderKit
import os.log

/// 将文档复制的 SF Symbol 栅格化为透明 PNG data URL，供 WebKit 以 CSS mask 显示。
///
/// 设计要点：
/// - `@MainActor`：所有 AppKit 栅格化只在主线程发生；
/// - 跨层只传递 `Sendable` 的 `DocumentCopyWebIcons`（纯 String data URL），
///   绝不外泄 `NSImage` / `NSBitmapImageRep` / graphics context；
/// - 缓存键为 { 配置版本, 离散倍率 }：同一键最多栅格化 `doc.on.doc` 与 `checkmark`
///   各一次；文件切换、整页 reload、raw/rendered 切换、正文更新、点击与计时复位全部命中缓存；
/// - 失败也缓存（`.unavailable`）并记录一次错误，不重试、不 crash。
///
/// 注入式 rasterizer seam：生产用真实 AppKit 实现，测试以计数 closure 注入，
/// 不向产品设置暴露测试 hook。
@MainActor
public final class SFSymbolWebImageProvider {

    public static let shared = SFSymbolWebImageProvider()

    // MARK: - 配置（任一变更须 bump configurationVersion 以失效旧缓存）

    /// 配置版本：覆盖两个 symbol、11 pt、Regular weight 与 14 pt 画布。
    /// 11 pt SF Symbol 以其配置后固有尺寸居中绘制于 14 pt 透明画布（不缩放成正方形）。
    /// 调整任一参数时递增，使旧缓存键失效。
    private static let configurationVersion = 2

    /// 逻辑画布尺寸（pt）。SF Symbol 以 11 pt 居中绘制于该透明画布。
    private static let canvasPoints: CGFloat = 14

    /// SF Symbol 渲染点数，与原生 SwiftUI `Image(systemName:).font(.system(size: 11))` 一致。
    private static let symbolPointSize: CGFloat = 11

    // MARK: - 离散倍率归一化

    /// 将任意 `backingScaleFactor` / SwiftUI `displayScale` 归一化为离散像素密度。
    ///
    /// 不能直接以任意 `CGFloat` 作 key：1.9 与 2.0 应共享同一缓存条目。
    /// 取 `round()` 并钳制到 ≥1。
    static func normalizedDisplayScale(_ scale: CGFloat) -> Int {
        max(1, Int(scale.rounded(.toNearestOrAwayFromZero)))
    }

    // MARK: - 缓存

    private struct CacheKey: Hashable, Sendable {
        let configurationVersion: Int
        let displayScale: Int
    }

    private enum CachedResult: Sendable {
        case available(DocumentCopyWebIcons)
        case unavailable
    }

    private var cache: [CacheKey: CachedResult] = [:]

    // MARK: - 注入式 rasterizer seam

    /// 栅格化闭包类型：给定离散倍率，返回两个符号的 PNG `Data`，或 `nil` 表示失败。
    ///
    /// 隔离于 `@MainActor`——所有 AppKit 栅格化只在主线程发生，闭包仅在主线程被调用，
    /// 故无需跨 actor。测试注入的计数 closure 同样运行在 `@MainActor` 测试上下文。
    typealias Rasterizer = @MainActor (Int) -> (copy: Data, copied: Data)?

    private let rasterizer: Rasterizer

    /// 生产初始化：使用真实 AppKit 栅格化。
    private init() {
        self.rasterizer = Self.makeDefaultRasterizer()
    }

    /// 测试初始化：注入计数 closure。`internal` 可见性，不暴露给产品设置。
    init(rasterizer: @escaping Rasterizer) {
        self.rasterizer = rasterizer
    }

    // MARK: - 公共 API

    /// 返回指定 `displayScale` 下的文档复制图标 data URL。
    ///
    /// 命中缓存即直接返回；否则栅格化两个符号各一次，成功则缓存可用结果，
    /// 失败则缓存 `.unavailable` 并记录一次错误。绝不重试已失败的倍率。
    public func documentCopyWebIcons(displayScale: CGFloat) -> DocumentCopyWebIcons {
        let scale = Self.normalizedDisplayScale(displayScale)
        let key = CacheKey(
            configurationVersion: Self.configurationVersion,
            displayScale: scale
        )

        if let cached = cache[key] {
            switch cached {
            case .available(let icons): return icons
            case .unavailable: return .unavailable
            }
        }

        guard let pair = rasterizer(scale) else {
            Self.logger.error("SFSymbolWebImageProvider: rasterization failed for scale=\(scale), caching unavailable")
            cache[key] = .unavailable
            return .unavailable
        }

        let icons = DocumentCopyWebIcons(
            copyMaskDataURL: Self.dataURL(from: pair.copy),
            copiedMaskDataURL: Self.dataURL(from: pair.copied)
        )
        cache[key] = .available(icons)
        return icons
    }

    // MARK: - 默认 AppKit 栅格化

    private static let logger = Logger(
        subsystem: "com.markdownreader.app",
        category: "SFSymbolWebImageProvider"
    )

    private static func makeDefaultRasterizer() -> Rasterizer {
        return { scale in
            guard let copyPNG = rasterize(symbol: DocumentCopySymbol.copy, scale: scale),
                  let copiedPNG = rasterize(symbol: DocumentCopySymbol.copied, scale: scale) else {
                return nil
            }
            return (copy: copyPNG, copied: copiedPNG)
        }
    }

    /// 将单个 SF Symbol 栅格化为保留 alpha 的透明 PNG。
    ///
    /// - 11 pt / Regular 配置，居中绘制于 14 pt 透明画布；
    /// - 按 `scale` 生成像素 bitmap（14×scale），保留 alpha；
    /// - 输出未着色模板 alpha 图形，颜色交由 WebKit `currentColor` 决定。
    private static func rasterize(symbol: DocumentCopySymbol, scale: Int) -> Data? {
        let points = canvasPoints
        let pixels = points * CGFloat(scale)

        guard let baseImage = NSImage(
            systemSymbolName: symbol.rawValue,
            accessibilityDescription: nil
        ) else {
            logger.error("rasterize: systemSymbolName unavailable for \(symbol.rawValue)")
            return nil
        }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: symbolPointSize,
            weight: .regular
        )
        let configured = baseImage.withSymbolConfiguration(configuration) ?? baseImage

        // 11 pt 配置后固有尺寸：与编辑模式 `.font(.system(size: 11))` 对齐的唯一原生尺寸来源。
        // 不缩放成正方形——以固有尺寸居中绘制，保留 SF Symbol 的原始比例。
        let intrinsicSize = configured.size
        guard intrinsicSize.width.isFinite, intrinsicSize.height.isFinite,
              intrinsicSize.width > 0, intrinsicSize.height > 0 else {
            logger.error("rasterize: invalid intrinsic size for \(symbol.rawValue)")
            return nil
        }

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels),
            pixelsHigh: Int(pixels),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else {
            logger.error("rasterize: NSBitmapImageRep alloc failed for \(symbol.rawValue)")
            return nil
        }
        bitmap.size = NSSize(width: points, height: points)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            logger.error("rasterize: graphics context failed for \(symbol.rawValue)")
            return nil
        }
        NSGraphicsContext.current = context

        // 透明画布：不填充背景，仅绘制符号 alpha。固有尺寸居中于 14 pt 画布。
        let drawRect = NSRect(
            x: (points - intrinsicSize.width) / 2,
            y: (points - intrinsicSize.height) / 2,
            width: intrinsicSize.width,
            height: intrinsicSize.height
        )
        configured.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func dataURL(from png: Data) -> String {
        "data:image/png;base64," + png.base64EncodedString()
    }
}
