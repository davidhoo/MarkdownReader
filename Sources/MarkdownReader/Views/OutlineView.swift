import SwiftUI
import MarkdownReaderKit

/// Markdown 文档大纲侧边栏，分级缩进显示标题结构
struct OutlineView: View {
    let items: [OutlineItem]
    let onSelect: (OutlineItem) -> Void
    var activeLineNumber: SourceLine?
    @Environment(\.themeColors) private var themeColors
    @Environment(\.language) private var language

    /// 最大显示层级（超过此层级的标题仍显示，但不增加缩进）
    private let maxIndentLevel: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 大纲标题
            outlineHeader

            Divider().background(themeColors.border)

            // 大纲列表
            if items.isEmpty {
                emptyOutline
            } else {
                outlineList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeColors.surface)
    }

    // MARK: - 大纲标题

    private var outlineHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 12))
                .foregroundStyle(themeColors.fgMuted)
            Text(L10n.tr(.outlineTitle, language: language))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themeColors.fgMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 空状态

    private var emptyOutline: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 20))
                .foregroundStyle(themeColors.fgMuted)
            Text(L10n.tr(.outlineEmpty, language: language))
                .font(.system(size: 11))
                .foregroundStyle(themeColors.fgMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 大纲列表

    private var outlineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    outlineRow(item)
                }
            }
            .padding(.vertical, 4)
            .background(OverlayScrollerHelper())
        }
        .scrollIndicators(.automatic)
    }

    // MARK: - 大纲行

    private func outlineRow(_ item: OutlineItem) -> some View {
        let indent = min(item.level - 1, maxIndentLevel - 1)

        return Button {
            onSelect(item)
        } label: {
            HStack(spacing: 0) {
                // 缩进
                Spacer().frame(width: CGFloat(indent) * 14 + 8)

                // 层级指示点
                Circle()
                    .fill(themeColors.fgMuted)
                    .frame(width: 4, height: 4)

                Text(item.title)
                    .font(.system(size: fontSize(for: item.level)))
                    .foregroundStyle(foregroundColor(for: item.level))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 6)
                    .padding(.vertical, 4)

                Spacer()
            }
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverBackground(themeColors: themeColors, isActive: item.sourceLine == activeLineNumber)
    }

    // MARK: - 样式辅助

    /// 根据标题层级返回字号
    private func fontSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 13
        case 2: return 12.5
        case 3: return 12
        default: return 11.5
        }
    }

    /// 根据标题层级返回前景色
    private func foregroundColor(for level: Int) -> Color {
        switch level {
        case 1: return themeColors.ink
        case 2: return themeColors.fgSecondary
        default: return themeColors.fgMuted
        }
    }
}

// MARK: - Hover 背景效果

/// 自定义 ButtonStyle，鼠标悬停时显示背景色
private struct HoverBackgroundButtonStyle: ButtonStyle {
    let themeColors: ThemeColors
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? themeColors.accentSoft : (configuration.isPressed ? themeColors.bgMuted : Color.clear))
            )
    }
}

extension View {
    func hoverBackground(themeColors: ThemeColors, isActive: Bool = false) -> some View {
        self.buttonStyle(HoverBackgroundButtonStyle(themeColors: themeColors, isActive: isActive))
    }
}
