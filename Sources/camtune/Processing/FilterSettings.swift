import Foundation
import Combine

final class FilterSettings: ObservableObject, Codable {
    static let neutralTemperature: Double = 6500

    // Basic
    @Published var brightness: Double = 0
    @Published var contrast: Double = 1
    @Published var saturation: Double = 1
    @Published var temperature: Double = neutralTemperature
    @Published var tint: Double = 0
    @Published var noiseLevel: Double = 0
    @Published var sharpness: Double = 0

    // AI assist
    @Published var lowLightBoost: Double = 0       // 0..1
    @Published var autoWhiteBalance: Bool = false
    @Published var portraitEnhance: Double = 0       // 0..1 (face-only color + smoothing)

    @Published var bypass: Bool = false

    private static let storageKey = "camtune.filterSettings.v1"
    private var autosaveCancellable: AnyCancellable?

    init(persisted: Bool = true) {
        if persisted {
            loadFromDefaults()
            // Persist whenever any @Published value changes; debounced so we
            // don't hit UserDefaults on every slider tick.
            autosaveCancellable = objectWillChange
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.saveToDefaults()
                }
        }
    }

    private func loadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let snapshot = try? JSONDecoder().decode(FilterSettingsSnapshot.self,
                                                       from: data) else { return }
        apply(snapshot)
    }

    private func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func reset() {
        brightness = 0
        contrast = 1
        saturation = 1
        temperature = FilterSettings.neutralTemperature
        tint = 0
        noiseLevel = 0
        sharpness = 0
        lowLightBoost = 0
        autoWhiteBalance = false
        portraitEnhance = 0
    }

    func apply(_ snapshot: FilterSettingsSnapshot) {
        brightness = snapshot.brightness
        contrast = snapshot.contrast
        saturation = snapshot.saturation
        temperature = snapshot.temperature
        tint = snapshot.tint
        noiseLevel = snapshot.noiseLevel
        sharpness = snapshot.sharpness
        lowLightBoost = snapshot.lowLightBoost
        autoWhiteBalance = snapshot.autoWhiteBalance
        portraitEnhance = snapshot.portraitEnhance
    }

    var snapshot: FilterSettingsSnapshot {
        FilterSettingsSnapshot(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            temperature: temperature,
            tint: tint,
            noiseLevel: noiseLevel,
            sharpness: sharpness,
            lowLightBoost: lowLightBoost,
            autoWhiteBalance: autoWhiteBalance,
            portraitEnhance: portraitEnhance
        )
    }

    // Codable conformance (Combine's @Published isn't auto-Codable)
    enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, temperature, tint, noiseLevel, sharpness
        case lowLightBoost, autoWhiteBalance, portraitEnhance
    }

    convenience init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try c.decode(Double.self, forKey: .brightness)
        contrast = try c.decode(Double.self, forKey: .contrast)
        saturation = try c.decode(Double.self, forKey: .saturation)
        temperature = try c.decode(Double.self, forKey: .temperature)
        tint = try c.decode(Double.self, forKey: .tint)
        noiseLevel = try c.decode(Double.self, forKey: .noiseLevel)
        sharpness = try c.decode(Double.self, forKey: .sharpness)
        lowLightBoost = try c.decodeIfPresent(Double.self, forKey: .lowLightBoost) ?? 0
        autoWhiteBalance = try c.decodeIfPresent(Bool.self, forKey: .autoWhiteBalance) ?? false
        portraitEnhance = try c.decodeIfPresent(Double.self, forKey: .portraitEnhance) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(noiseLevel, forKey: .noiseLevel)
        try c.encode(sharpness, forKey: .sharpness)
        try c.encode(lowLightBoost, forKey: .lowLightBoost)
        try c.encode(autoWhiteBalance, forKey: .autoWhiteBalance)
        try c.encode(portraitEnhance, forKey: .portraitEnhance)
    }
}

struct FilterSettingsSnapshot: Codable, Equatable {
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var temperature: Double
    var tint: Double
    var noiseLevel: Double
    var sharpness: Double
    var lowLightBoost: Double
    var autoWhiteBalance: Bool
    var portraitEnhance: Double
}
