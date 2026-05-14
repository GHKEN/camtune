import SwiftUI

struct ControlPanel: View {
    @ObservedObject var settings: FilterSettings
    @ObservedObject var presetPreviews: PresetPreviewRenderer

    @State private var advancedOpen: Bool = false

    private var currentPresetID: String? {
        BuiltInPresets.match(settings.snapshot)?.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("補正を有効にする", isOn: Binding(
                    get: { !settings.bypass },
                    set: { settings.bypass = !$0 }
                ))
                .toggleStyle(.switch)
                .font(.headline)

                Divider()

                Text("プリセット")
                    .font(.subheadline.bold())

                presetGrid

                Divider()

                DisclosureGroup("詳細設定", isExpanded: $advancedOpen) {
                    advancedSliders
                }
                .font(.subheadline.bold())
            }
            .padding()
        }
        .frame(minWidth: 320)
    }

    // MARK: - Preset tiles

    private var presetGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(BuiltInPresets.all) { preset in
                PresetTile(
                    preset: preset,
                    thumbnail: presetPreviews.thumbnails[preset.id],
                    isSelected: currentPresetID == preset.id
                ) {
                    settings.apply(preset.snapshot)
                }
            }
        }
    }

    // MARK: - Advanced sliders

    @ViewBuilder
    private var advancedSliders: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("基本色調整") {
                sliderRow("明度", value: $settings.brightness,
                          range: -0.5...0.5, neutral: 0, format: "%.2f")
                sliderRow("コントラスト", value: $settings.contrast,
                          range: 0.5...1.5, neutral: 1, format: "%.2f")
                sliderRow("彩度", value: $settings.saturation,
                          range: 0.0...2.0, neutral: 1, format: "%.2f")
            }
            section("色温度・ティント") {
                sliderRow("色温度 (左:暖色←  6500K  →右:寒色)",
                          value: $settings.temperature,
                          range: 3000...9000,
                          neutral: FilterSettings.neutralTemperature,
                          format: "%.0fK")
                sliderRow("ティント", value: $settings.tint,
                          range: -100...100, neutral: 0, format: "%.0f")
            }
            section("ノイズリダクション") {
                sliderRow("強さ", value: $settings.noiseLevel,
                          range: 0...0.1, neutral: 0, format: "%.3f")
                sliderRow("シャープネス", value: $settings.sharpness,
                          range: 0...2, neutral: 0, format: "%.2f")
            }
            section("AI 補正") {
                Toggle("自動ホワイトバランス", isOn: $settings.autoWhiteBalance)
                    .toggleStyle(.switch).font(.caption)
                sliderRow("ローライト補正", value: $settings.lowLightBoost,
                          range: 0...1, neutral: 0, format: "%.2f")
                sliderRow("ポートレート補正", value: $settings.portraitEnhance,
                          range: 0...1, neutral: 0, format: "%.2f")
            }
            HStack {
                Button("初期値に戻す") { settings.reset() }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func sliderRow(_ label: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           neutral: Double,
                           format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    value.wrappedValue = neutral
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("中立値に戻す")
            }
            Slider(value: value, in: range)
        }
    }
}

private struct PresetTile: View {
    let preset: BuiltInPreset
    let thumbnail: NSImage?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(x: -1, y: 1)
                            .frame(maxWidth: .infinity)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.15))
                            .aspectRatio(16/9, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear,
                                      lineWidth: 3)
                )

                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.name)
                        .font(.caption.bold())
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(preset.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
