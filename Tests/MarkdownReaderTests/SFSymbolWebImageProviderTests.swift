import AppKit
import MarkdownReaderKit
import XCTest
@testable import MarkdownReader

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
