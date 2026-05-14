import Foundation
import CoreImage
import CoreGraphics
import Combine
import AppKit

/// Renders a thumbnail of the live camera frame through each built-in preset.
/// Thumbnails are produced at ~1 fps on a utility queue and exposed as a
/// dictionary keyed by preset id.
final class PresetPreviewRenderer: ObservableObject {
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    private let ciContext: CIContext
    private var subscription: AnyCancellable?
    private var renderQueue = DispatchQueue(label: "camtune.preset.preview",
                                            qos: .utility)
    private var pipelines: [String: FilterPipeline] = [:]

    // Render at 2x logical size so retina displays don't blur upscaled tiles.
    private let thumbWidth: CGFloat = 320
    private let thumbHeight: CGFloat = 180
    private let displayWidth: CGFloat = 160
    private let displayHeight: CGFloat = 90

    init() {
        ciContext = CIContext(options: [.cacheIntermediates: false])
        // Build one pipeline per preset, with a non-persisted FilterSettings
        // so they don't write to UserDefaults.
        for preset in BuiltInPresets.all {
            let settings = FilterSettings(persisted: false)
            settings.apply(preset.snapshot)
            pipelines[preset.id] = FilterPipeline(settings: settings)
        }
    }

    func subscribe(to publisher: AnyPublisher<CIImage, Never>) {
        subscription?.cancel()
        subscription = publisher
            // Throttle to ~1 fps; thumbnails don't need to be fluid.
            .throttle(for: .seconds(1.0), scheduler: renderQueue, latest: true)
            .sink { [weak self] image in
                self?.renderAll(rawImage: image)
            }
    }

    deinit { subscription?.cancel() }

    private func renderAll(rawImage: CIImage) {
        // Downsample to thumbnail size first.
        let srcW = rawImage.extent.width
        let srcH = rawImage.extent.height
        guard srcW > 0, srcH > 0 else { return }
        let scale = min(thumbWidth / srcW, thumbHeight / srcH)
        let scaled = rawImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let originX = scaled.extent.origin.x
        let originY = scaled.extent.origin.y
        let normalized = scaled.transformed(by: CGAffineTransform(
            translationX: -originX, y: -originY
        ))

        var results: [String: NSImage] = [:]
        let bounds = CGRect(x: 0, y: 0,
                            width: normalized.extent.width,
                            height: normalized.extent.height)
        for preset in BuiltInPresets.all {
            guard let pipeline = pipelines[preset.id] else { continue }
            let processed = pipeline.process(normalized).cropped(to: bounds)
            guard let cgImage = ciContext.createCGImage(processed, from: bounds) else {
                continue
            }
            let nsImage = NSImage(cgImage: cgImage,
                                  size: NSSize(width: displayWidth,
                                                height: displayHeight))
            results[preset.id] = nsImage
        }
        DispatchQueue.main.async { [weak self] in
            self?.thumbnails = results
        }
    }
}
