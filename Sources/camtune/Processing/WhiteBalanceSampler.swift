import CoreImage
import Foundation
import simd

/// Estimates per-channel gains for grey-world automatic white balance.
/// Samples are taken at most every `minInterval`, with exponential smoothing
/// to avoid flicker.
final class WhiteBalanceSampler {
    private let context: CIContext
    private let areaAverageFilter = CIFilter(name: "CIAreaAverage")!
    private var cachedGains: SIMD3<Float> = SIMD3(1, 1, 1)
    private var lastSampleAt: TimeInterval = 0
    private let minInterval: TimeInterval = 0.2
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(context: CIContext) {
        self.context = context
    }

    /// Returns smoothed R/G/B gains. Re-samples at most once every 200ms.
    func gains(for image: CIImage) -> SIMD3<Float> {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastSampleAt < minInterval {
            return cachedGains
        }
        lastSampleAt = now

        areaAverageFilter.setValue(image, forKey: kCIInputImageKey)
        areaAverageFilter.setValue(CIVector(cgRect: image.extent), forKey: kCIInputExtentKey)
        guard let averageImage = areaAverageFilter.outputImage else {
            return cachedGains
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            averageImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        let r = max(Float(pixel[0]) / 255.0, 0.02)
        let g = max(Float(pixel[1]) / 255.0, 0.02)
        let b = max(Float(pixel[2]) / 255.0, 0.02)
        let mean = (r + g + b) / 3.0
        let target = SIMD3<Float>(mean / r, mean / g, mean / b)

        // Clamp to avoid extreme corrections that look unnatural.
        let clamped = SIMD3<Float>(
            min(max(target.x, 0.6), 1.6),
            min(max(target.y, 0.6), 1.6),
            min(max(target.z, 0.6), 1.6)
        )

        // Exponential smoothing.
        let alpha: Float = 0.15
        cachedGains = cachedGains * (1 - alpha) + clamped * alpha
        return cachedGains
    }

    func reset() {
        cachedGains = SIMD3(1, 1, 1)
        lastSampleAt = 0
    }
}
