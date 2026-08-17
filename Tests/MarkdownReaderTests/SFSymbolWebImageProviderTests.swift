import AppKit
import MarkdownReaderKit
@testable import MarkdownReaderKit
import XCTest

/// SF Symbol → 透明 PNG → data URL 提供者单测。
///
/// 分两类：
/// - 真实栅格化（`.shared`）：验证 data URL 形态、1×/2× 像素尺寸与 alpha；
/// - 注入式 rasterizer：验证 {配置版本, 离散倍率} 缓存的 miss/hit 与失败缓存。
///
/// 不比较 PNG 像素哈希——系统可在不同 macOS 版本更新 SF Symbol 轮廓。
@MainActor
final class SFSymbolWebImageProviderTests: XCTestCase {

    // MARK: - 真实栅格化：data URL 与 PNG 尺寸 / alpha

    func testDataURLsArePNGBase64() {
        let provider = SFSymbolWebImageProvider.shared
        let icons = provider.documentCopyWebIcons(displayScale: 1)

        XCTAssertTrue(icons.copyMaskDataURL.hasPrefix("data:image/png;base64,"))
        XCTAssertTrue(icons.copiedMaskDataURL.hasPrefix("data:image/png;base64,"))
    }

    func testOneXBitmapIs14x14WithAlpha() {
        let provider = SFSymbolWebImageProvider.shared
        let icons = provider.documentCopyWebIcons(displayScale: 1)

        let copyRep = bitmapRep(from: icons.copyMaskDataURL)
        let copiedRep = bitmapRep(from: icons.copiedMaskDataURL)

        XCTAssertEqual(copyRep.pixelsWide, 14)
        XCTAssertEqual(copyRep.pixelsHigh, 14)
        XCTAssertTrue(copyRep.hasAlpha)
        XCTAssertTrue(hasNonTransparentPixels(copyRep))

        XCTAssertEqual(copiedRep.pixelsWide, 14)
        XCTAssertEqual(copiedRep.pixelsHigh, 14)
        XCTAssertTrue(copiedRep.hasAlpha)
        XCTAssertTrue(hasNonTransparentPixels(copiedRep))
    }

    func testTwoXBitmapIs28x28WithAlpha() {
        let provider = SFSymbolWebImageProvider.shared
        let icons = provider.documentCopyWebIcons(displayScale: 2)

        let copyRep = bitmapRep(from: icons.copyMaskDataURL)
        let copiedRep = bitmapRep(from: icons.copiedMaskDataURL)

        XCTAssertEqual(copyRep.pixelsWide, 28)
        XCTAssertEqual(copyRep.pixelsHigh, 28)
        XCTAssertTrue(copyRep.hasAlpha)
        XCTAssertTrue(hasNonTransparentPixels(copyRep))

        XCTAssertEqual(copiedRep.pixelsWide, 28)
        XCTAssertEqual(copiedRep.pixelsHigh, 28)
        XCTAssertTrue(copiedRep.hasAlpha)
    }

    // MARK: - 原始比例与居中：与 11 pt 原生 SF Symbol 对齐

    /// 渲染模式默认态 `doc.on.doc` 与成功态 `checkmark` 必须保留 11 pt SF Symbol 的固有尺寸与比例，
    /// 居中绘制于 14 pt 透明画布——而不是被强制缩放成正方形。
    ///
    /// 此处用一个独立于生产 `rasterize` 的参考绘制 helper 冻结可观察合同：以
    /// `configured.size` 居中绘制到 14 pt 透明 bitmap，再比对 provider 输出 PNG 与参考 bitmap
    /// 的非透明 alpha 外接边界（x/y/width/height）。只比较边界而非像素哈希，
    /// 因为 SF Symbol 抗锯齿会随 macOS 更新；本测试只冻结比例、尺寸与居中。
    func testRasterizedSymbolsMatchNativeElevenPointAspectAndCentering() {
        let provider = SFSymbolWebImageProvider.shared
        let icons = provider.documentCopyWebIcons(displayScale: 1)

        let cases: [(DocumentCopySymbol, String)] = [
            (.copy, icons.copyMaskDataURL),
            (.copied, icons.copiedMaskDataURL),
        ]

        for (symbol, dataURL) in cases {
            guard let providerRep = decodedPNG(from: dataURL) else {
                XCTFail("provider PNG 解码失败 for \(symbol.rawValue)")
                continue
            }
            guard let providerBounds = alphaBounds(in: providerRep) else {
                XCTFail("provider 输出无可见像素 for \(symbol.rawValue)")
                continue
            }
            guard let referenceBounds = referenceAlphaBounds(for: symbol) else {
                XCTFail("11 pt 原生参考栅格化失败 for \(symbol.rawValue)")
                continue
            }
            XCTAssertEqual(providerBounds.x, referenceBounds.x, "\(symbol.rawValue): x 不一致")
            XCTAssertEqual(providerBounds.y, referenceBounds.y, "\(symbol.rawValue): y 不一致")
            XCTAssertEqual(providerBounds.width, referenceBounds.width, "\(symbol.rawValue): width 不一致")
            XCTAssertEqual(providerBounds.height, referenceBounds.height, "\(symbol.rawValue): height 不一致")
        }
    }

    // MARK: - 缓存：注入计数 rasterizer

    func testSameScaleReusesCacheAndRasterizesOnce() {
        var rasterizerCallCount = 0
        let stubPNG = Self.opaqueStubPNG()
        let provider = SFSymbolWebImageProvider { _ in
            rasterizerCallCount += 1
            return (copy: stubPNG, copied: stubPNG)
        }

        let first = provider.documentCopyWebIcons(displayScale: 2)
        let second = provider.documentCopyWebIcons(displayScale: 2)

        XCTAssertEqual(rasterizerCallCount, 1, "同倍率应只栅格化一个批次")
        XCTAssertEqual(first, second)
    }

    func testDifferentScalesRasterizeOnceEachThenHit() {
        var calls = Set<Int>()
        let stubPNG = Self.opaqueStubPNG()
        let provider = SFSymbolWebImageProvider { scale in
            XCTAssertFalse(calls.contains(scale), "rasterizer 对倍率 \(scale) 被调用两次")
            calls.insert(scale)
            return (copy: stubPNG, copied: stubPNG)
        }

        _ = provider.documentCopyWebIcons(displayScale: 1)
        _ = provider.documentCopyWebIcons(displayScale: 2)
        _ = provider.documentCopyWebIcons(displayScale: 1) // 命中
        _ = provider.documentCopyWebIcons(displayScale: 2) // 命中

        XCTAssertEqual(calls, [1, 2])
    }

    func testNonIntegerScaleNormalizesToDiscreteDensity() {
        var calls = Set<Int>()
        let stubPNG = Self.opaqueStubPNG()
        let provider = SFSymbolWebImageProvider { scale in
            calls.insert(scale)
            return (copy: stubPNG, copied: stubPNG)
        }

        _ = provider.documentCopyWebIcons(displayScale: 2.0)
        _ = provider.documentCopyWebIcons(displayScale: 1.9) // 归一化为 2

        XCTAssertEqual(calls, [2], "1.9 应归一化到离散倍率 2 并命中缓存")
    }

    // MARK: - 降级：失败缓存 unavailable，不重试

    func testRasterizerFailureReturnsUnavailableAndCaches() {
        var callCount = 0
        let provider = SFSymbolWebImageProvider { _ in
            callCount += 1
            return nil
        }

        let first = provider.documentCopyWebIcons(displayScale: 1)
        let second = provider.documentCopyWebIcons(displayScale: 1)

        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(second, .unavailable)
        XCTAssertEqual(callCount, 1, "失败应缓存，不重试")
    }

    // MARK: - Helpers

    private func bitmapRep(from dataURL: String) -> NSBitmapImageRep {
        let prefix = "data:image/png;base64,"
        XCTAssertTrue(dataURL.hasPrefix(prefix))
        let base64 = String(dataURL.dropFirst(prefix.count))
        let data = Data(base64Encoded: base64)
        XCTAssertNotNil(data, "data URL base64 解码失败")
        let rep = NSBitmapImageRep(data: data!)
        XCTAssertNotNil(rep, "PNG 解码失败")
        return rep!
    }

    private func hasNonTransparentPixels(_ rep: NSBitmapImageRep) -> Bool {
        guard let tiff = rep.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return false }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent, alpha > 0 {
                    return true
                }
            }
        }
        return false
    }

    /// 解码 data URL 为 PNG bitmap，失败返回 nil（不做强制断言）。
    private func decodedPNG(from dataURL: String) -> NSBitmapImageRep? {
        let prefix = "data:image/png;base64,"
        guard dataURL.hasPrefix(prefix) else { return nil }
        let base64 = String(dataURL.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    /// 计算非透明像素的外接矩形（像素坐标，左下原点与 NSBitmapImageRep 一致）。
    /// 返回 (x, y, width, height)；无可见像素返回 nil。
    private func alphaBounds(in rep: NSBitmapImageRep) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let tiff = rep.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent, alpha > 0 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// 独立于生产 `rasterize` 的 11 pt 原生参考绘制：以 `configured.size`（不缩放）居中
    /// 绘制到 14 pt 透明 bitmap（1× = 14×14 px），返回其 alpha 外接矩形。
    /// 与生产实现刻意分开，避免共享同一 drawRect 导致测试与实现同错。
    private func referenceAlphaBounds(for symbol: DocumentCopySymbol) -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let base = NSImage(systemSymbolName: symbol.rawValue, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let configured = base.withSymbolConfiguration(configuration) ?? base
        let intrinsic = configured.size
        guard intrinsic.width.isFinite, intrinsic.height.isFinite,
              intrinsic.width > 0, intrinsic.height > 0 else {
            return nil
        }

        let points: CGFloat = 14
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 14,
            pixelsHigh: 14,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: points, height: points)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context

        let drawRect = NSRect(
            x: (points - intrinsic.width) / 2,
            y: (points - intrinsic.height) / 2,
            width: intrinsic.width,
            height: intrinsic.height
        )
        configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        return alphaBounds(in: bitmap)
    }

    /// 生成一个稳定的小 PNG stub，供缓存计数测试使用（不参与尺寸断言）。
    private static func opaqueStubPNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }
}
