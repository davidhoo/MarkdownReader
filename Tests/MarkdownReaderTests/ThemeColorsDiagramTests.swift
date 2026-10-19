import MarkdownReaderKit
import XCTest

/// Pele 图底色应贴着当前主题的阅读表面，而不是偏重的卡片色。
final class ThemeColorsDiagramTests: XCTestCase {

    func testDiagramBackgroundMatchesThemeSurface() {
        let dark = ThemeColors.from(PresetThemes.darkThemes[0])
        let light = ThemeColors.from(PresetThemes.lightThemes[0])

        for colors in [dark, light] {
            let background = diagramToken("--diagram-bg:", in: colors)
            XCTAssertEqual(background, diagramToken("--surface:", in: colors))
            XCTAssertNotEqual(background, diagramToken("--bg-elevated:", in: colors))
            XCTAssertNotEqual(background, diagramToken("--diagram-node:", in: colors))
            XCTAssertNotEqual(diagramToken("--diagram-node:", in: colors), diagramToken("--diagram-cluster:", in: colors))
        }
    }

    private func diagramToken(_ name: String, in colors: ThemeColors) -> String {
        let css = colors.cssCustomProperties
        guard let start = css.range(of: name) else {
            return ""
        }
        let rest = css[start.upperBound...]
        let end = rest.firstIndex(of: ";") ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespaces)
    }
}
