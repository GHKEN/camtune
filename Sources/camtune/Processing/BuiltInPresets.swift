import Foundation

struct BuiltInPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let snapshot: FilterSettingsSnapshot
}

private func makeSnapshot(
    brightness: Double = 0,
    contrast: Double = 1,
    saturation: Double = 1,
    temperature: Double = FilterSettings.neutralTemperature,
    tint: Double = 0,
    noiseLevel: Double = 0,
    sharpness: Double = 0,
    lowLightBoost: Double = 0,
    autoWhiteBalance: Bool = false,
    portraitEnhance: Double = 0
) -> FilterSettingsSnapshot {
    return FilterSettingsSnapshot(
        brightness: brightness, contrast: contrast, saturation: saturation,
        temperature: temperature, tint: tint,
        noiseLevel: noiseLevel, sharpness: sharpness,
        lowLightBoost: lowLightBoost,
        autoWhiteBalance: autoWhiteBalance,
        portraitEnhance: portraitEnhance
    )
}

enum BuiltInPresets {
    static let all: [BuiltInPreset] = [
        BuiltInPreset(
            id: "original",
            name: "オリジナル",
            subtitle: "補正なし",
            snapshot: makeSnapshot()
        ),
        BuiltInPreset(
            id: "clear",
            name: "クリア",
            subtitle: "明るく自然に",
            snapshot: makeSnapshot(
                brightness: 0.08,
                contrast: 1.08,
                saturation: 1.15,
                autoWhiteBalance: true
            )
        ),
        BuiltInPreset(
            id: "warm",
            name: "暖色",
            subtitle: "オレンジ寄り",
            snapshot: makeSnapshot(
                temperature: FilterSettings.neutralTemperature - 1500
            )
        ),
        BuiltInPreset(
            id: "cool",
            name: "寒色",
            subtitle: "ブルー寄り",
            snapshot: makeSnapshot(
                temperature: FilterSettings.neutralTemperature + 1500
            )
        ),
        BuiltInPreset(
            id: "portrait",
            name: "ポートレート",
            subtitle: "顔だけ整える",
            snapshot: makeSnapshot(
                autoWhiteBalance: true,
                portraitEnhance: 1.0
            )
        ),
        BuiltInPreset(
            id: "lowlight",
            name: "ローライト",
            subtitle: "暗所を明るく",
            snapshot: makeSnapshot(
                brightness: 0.1,
                noiseLevel: 0.03,
                sharpness: 1.0,
                lowLightBoost: 1.0,
                autoWhiteBalance: true,
                portraitEnhance: 0.4
            )
        ),
        BuiltInPreset(
            id: "cinema",
            name: "シネマ",
            subtitle: "映画的トーン",
            snapshot: makeSnapshot(
                brightness: -0.05,
                contrast: 1.30,
                saturation: 0.70,
                temperature: FilterSettings.neutralTemperature - 400,
                tint: 5
            )
        ),
        BuiltInPreset(
            id: "vivid",
            name: "ビビッド",
            subtitle: "鮮やか会議向け",
            snapshot: makeSnapshot(
                brightness: 0.1,
                contrast: 1.15,
                saturation: 1.4,
                noiseLevel: 0.015,
                lowLightBoost: 0.3,
                autoWhiteBalance: true,
                portraitEnhance: 0.5
            )
        ),
    ]

    static func match(_ snapshot: FilterSettingsSnapshot) -> BuiltInPreset? {
        return all.first { $0.snapshot == snapshot }
    }
}
