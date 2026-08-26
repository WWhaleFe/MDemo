import MemoCore
import SwiftUI

/// 메모 하나의 겉모습을 바꾸는 패널 (WIN-11, OPA-01/02/03).
///
/// 배경과 텍스트의 투명도를 따로 조절한다. 창 전체를 흐리게 만들면 글씨까지 읽기 어려워지므로,
/// 배경만 비치게 하고 글씨는 또렷하게 두는 것이 이 앱의 방식이다.
struct StickyAppearanceView: View {
    let initialColorHex: String
    let initialBackgroundAlpha: Double
    let initialTextAlpha: Double
    let isPinned: Bool

    let onColorChange: (String) -> Void
    let onBackgroundAlphaChange: (Double) -> Void
    let onTextAlphaChange: (Double) -> Void
    let onPinnedChange: (Bool) -> Void

    @State private var colorHex: String
    @State private var backgroundAlpha: Double
    @State private var textAlpha: Double
    @State private var pinned: Bool

    init(
        colorHex: String,
        backgroundAlpha: Double,
        textAlpha: Double,
        isPinned: Bool,
        onColorChange: @escaping (String) -> Void,
        onBackgroundAlphaChange: @escaping (Double) -> Void,
        onTextAlphaChange: @escaping (Double) -> Void,
        onPinnedChange: @escaping (Bool) -> Void
    ) {
        self.initialColorHex = colorHex
        self.initialBackgroundAlpha = backgroundAlpha
        self.initialTextAlpha = textAlpha
        self.isPinned = isPinned
        self.onColorChange = onColorChange
        self.onBackgroundAlphaChange = onBackgroundAlphaChange
        self.onTextAlphaChange = onTextAlphaChange
        self.onPinnedChange = onPinnedChange

        _colorHex = State(initialValue: colorHex)
        _backgroundAlpha = State(initialValue: backgroundAlpha)
        _textAlpha = State(initialValue: textAlpha)
        _pinned = State(initialValue: isPinned)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            colorSection
            Divider()
            opacitySection
            Divider()
            Toggle("항상 위에 두기", isOn: $pinned)
                .onChange(of: pinned) { _, value in onPinnedChange(value) }
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: - 배경색 (WIN-11)

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("배경색").font(.caption).foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(MemoColor.presets, id: \.hex) { preset in
                    swatch(for: preset)
                }
            }
        }
    }

    private func swatch(for preset: MemoColor) -> some View {
        let isSelected = preset.hex.caseInsensitiveCompare(colorHex) == .orderedSame
        return Circle()
            .fill(color(from: preset.hex))
            .frame(height: 26)
            .overlay(
                Circle().strokeBorder(
                    isSelected ? Color.accentColor : Color.black.opacity(0.12),
                    lineWidth: isSelected ? 2.5 : 1
                )
            )
            .contentShape(Circle())
            .onTapGesture {
                colorHex = preset.hex
                onColorChange(preset.hex)
            }
            .help(preset.name)
    }

    // MARK: - 투명도 (OPA-01, OPA-02, OPA-03)

    private var opacitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(
                title: "배경 투명도",
                value: $backgroundAlpha,
                range: MemoMeta.backgroundAlphaRange,
                onChange: onBackgroundAlphaChange
            )
            sliderRow(
                title: "글자 투명도",
                value: $textAlpha,
                range: MemoMeta.textAlphaRange,
                onChange: onTextAlphaChange
            )
            Text("배경만 비치게 하고 글씨는 또렷하게 둘 수 있습니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            // 슬라이더가 갈 수 있는 범위 자체를 제한해, 창을 잃어버릴 만큼
            // 투명해지는 일이 아예 없게 한다 (OPA-03).
            Slider(value: value, in: range)
                .controlSize(.small)
                .onChange(of: value.wrappedValue) { _, newValue in onChange(newValue) }
        }
    }

    private func color(from hex: String) -> Color {
        guard let rgb = MemoColor.components(fromHex: hex) else { return .gray }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
