import SwiftUI
import MarkdownReaderKit

struct FindReplaceBar: View {
    @Bindable var viewModel: FindReplaceViewModel
    let isRawMode: Bool
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.themeColors) private var themeColors
    @Environment(\.language) private var language

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            chevronColumn
            inputColumn
            buttonColumn
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(themeColors.surface.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(themeColors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 6)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { isSearchFieldFocused = true }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    // MARK: - Column 1: Chevron

    private var chevronColumn: some View {
        VStack(alignment: .center, spacing: 0) {
            Button {
                viewModel.isReplaceExpanded.toggle()
            } label: {
                Image(systemName: viewModel.isReplaceExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(themeColors.fgSecondary)
                    .frame(width: 16, height: 24)
            }
            .buttonStyle(.plain)

            if viewModel.isReplaceExpanded {
                Color.clear.frame(width: 16, height: 24)
            }
        }
    }

    // MARK: - Column 2: Input Fields

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: viewModel.isReplaceExpanded ? 2 : 0) {
            searchField

            if viewModel.isReplaceExpanded {
                replaceField
            }
        }
    }

    private var searchField: some View {
        ZStack(alignment: .trailing) {
            TextField(L10n.tr(.findBarSearchPlaceholder, language: language), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(themeColors.bgSubtle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(viewModel.totalMatchCount == 0 && !viewModel.searchText.isEmpty ? themeColors.danger : themeColors.border, lineWidth: 1)
                )
                .focused($isSearchFieldFocused)
                .onKeyPress(.return, phases: .down) { context in
                    // Enter = 下一个，Shift+Enter = 上一个
                    if context.modifiers.contains(.shift) {
                        onFindPrevious()
                    } else {
                        onFindNext()
                    }
                    return .handled
                }

            if !viewModel.searchText.isEmpty {
                Text(viewModel.matchDisplayText)
                    .font(.system(size: 11))
                    .foregroundStyle(viewModel.totalMatchCount == 0 ? themeColors.danger : themeColors.fgMuted)
                    .padding(.trailing, 6)
            }
        }
    }

    private var replaceField: some View {
        TextField(L10n.tr(.findBarReplacePlaceholder, language: language), text: $viewModel.replaceText)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(themeColors.bgSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(themeColors.border, lineWidth: 1)
            )
    }

    // MARK: - Column 3: Buttons

    private var buttonColumn: some View {
        VStack(alignment: .leading, spacing: viewModel.isReplaceExpanded ? 0 : 0) {
            HStack(spacing: 4) {
                optionToggle(isOn: $viewModel.isCaseSensitive, label: "Aa", tooltip: L10n.tr(.findBarCaseSensitive, language: language))
                optionToggle(isOn: $viewModel.isWholeWord, label: "W*", tooltip: L10n.tr(.findBarWholeWord, language: language))
                optionToggle(isOn: $viewModel.isRegularExpression, label: ".*", tooltip: L10n.tr(.findBarRegularExpression, language: language))

                Button { onFindPrevious() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.totalMatchCount == 0)

                Button { onFindNext() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(themeColors.fgSecondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.totalMatchCount == 0)

                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(themeColors.fgMuted)
                }
                .buttonStyle(.plain)
            }

            if viewModel.isReplaceExpanded {
                HStack(spacing: 4) {
                    replaceButton(title: L10n.tr(.findBarReplace, language: language)) {
                        onReplace()
                    }
                    .disabled(!isRawMode || viewModel.totalMatchCount == 0)

                    replaceButton(title: L10n.tr(.findBarReplaceAll, language: language)) {
                        onReplaceAll()
                    }
                    .disabled(!isRawMode || viewModel.totalMatchCount == 0)
                }
                .frame(height: 24)
            }
        }
    }

    // MARK: - Button Helpers

    private func replaceButton(title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isRawMode ? themeColors.fgSecondary : themeColors.fgMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(themeColors.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func optionToggle(isOn: Binding<Bool>, label: String, tooltip: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? themeColors.accent : themeColors.fgMuted)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn.wrappedValue ? themeColors.accent.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            if hovering {
                NSCursor.arrow.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
