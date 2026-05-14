import CoreImage
import Foundation

final class FilterPipeline {
    let settings: FilterSettings

    // Basic filters (reused per frame)
    private let tempTintFilter = CIFilter(name: "CITemperatureAndTint")!
    private let colorControlsFilter = CIFilter(name: "CIColorControls")!
    private let noiseFilter = CIFilter(name: "CINoiseReduction")!

    // AI-assist filters
    private let exposureFilter = CIFilter(name: "CIExposureAdjust")!
    private let toneCurveFilter = CIFilter(name: "CIToneCurve")!
    private let colorMatrixFilter = CIFilter(name: "CIColorMatrix")!
    private let blurFilter = CIFilter(name: "CIGaussianBlur")!
    private let blendWithMaskFilter = CIFilter(name: "CIBlendWithMask")!
    private let maxCompositingFilter = CIFilter(name: "CIMaximumCompositing")!

    // Dedicated filters for portrait enhance (separated from manual filters to avoid state collisions)
    private let portraitExposureFilter = CIFilter(name: "CIExposureAdjust")!
    private let portraitTempFilter = CIFilter(name: "CITemperatureAndTint")!
    private let portraitColorFilter = CIFilter(name: "CIColorControls")!
    private let portraitToneCurveFilter = CIFilter(name: "CIToneCurve")!

    private let faceDetector = FaceDetector()
    private let wbSampler: WhiteBalanceSampler
    private let context: CIContext

    init(settings: FilterSettings) {
        self.settings = settings
        self.context = CIContext(options: [.cacheIntermediates: false])
        self.wbSampler = WhiteBalanceSampler(context: context)
    }

    func process(_ input: CIImage) -> CIImage {
        let s = settings.snapshot
        if settings.bypass { return input }

        var image = input
        let originalExtent = input.extent

        // 1. Auto White Balance (operates on raw input — first so subsequent filters see corrected color)
        if s.autoWhiteBalance {
            let gains = wbSampler.gains(for: image)
            image = applyChannelGains(image, gains: gains)
        }

        // 2. Temperature & Tint (manual)
        let neutral = FilterSettings.neutralTemperature
        if s.temperature != neutral || s.tint != 0 {
            tempTintFilter.setValue(image, forKey: kCIInputImageKey)
            tempTintFilter.setValue(CIVector(x: CGFloat(neutral), y: 0), forKey: "inputNeutral")
            tempTintFilter.setValue(CIVector(x: CGFloat(s.temperature), y: CGFloat(s.tint)),
                                    forKey: "inputTargetNeutral")
            if let out = tempTintFilter.outputImage { image = out }
        }

        // 3. Low-light boost (exposure lift + shadow-lifting tone curve)
        if s.lowLightBoost > 0 {
            image = applyLowLightBoost(image, amount: s.lowLightBoost)
        }

        // 4. Color Controls
        if s.brightness != 0 || s.contrast != 1 || s.saturation != 1 {
            colorControlsFilter.setValue(image, forKey: kCIInputImageKey)
            colorControlsFilter.setValue(s.brightness, forKey: kCIInputBrightnessKey)
            colorControlsFilter.setValue(s.contrast, forKey: kCIInputContrastKey)
            colorControlsFilter.setValue(s.saturation, forKey: kCIInputSaturationKey)
            if let out = colorControlsFilter.outputImage { image = out }
        }

        // 5. Noise Reduction
        if s.noiseLevel > 0 || s.sharpness > 0 {
            noiseFilter.setValue(image, forKey: kCIInputImageKey)
            noiseFilter.setValue(s.noiseLevel, forKey: "inputNoiseLevel")
            noiseFilter.setValue(s.sharpness, forKey: "inputSharpness")
            if let out = noiseFilter.outputImage { image = out }
        }

        // 6. Portrait enhance (face-masked color lift + selective smoothing)
        if s.portraitEnhance > 0 {
            faceDetector.detectIfNeeded(in: image)
            let faces = faceDetector.faces
            if !faces.isEmpty {
                image = applyPortraitEnhance(image, faces: faces, amount: s.portraitEnhance)
            }
        }

        return image.cropped(to: originalExtent)
    }

    // MARK: - AI filter implementations

    private func applyChannelGains(_ image: CIImage, gains: SIMD3<Float>) -> CIImage {
        colorMatrixFilter.setValue(image, forKey: kCIInputImageKey)
        colorMatrixFilter.setValue(CIVector(x: CGFloat(gains.x), y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrixFilter.setValue(CIVector(x: 0, y: CGFloat(gains.y), z: 0, w: 0), forKey: "inputGVector")
        colorMatrixFilter.setValue(CIVector(x: 0, y: 0, z: CGFloat(gains.z), w: 0), forKey: "inputBVector")
        colorMatrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        colorMatrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return colorMatrixFilter.outputImage ?? image
    }

    private func applyLowLightBoost(_ image: CIImage, amount: Double) -> CIImage {
        let clamped = max(0, min(1, amount))
        // Exposure: up to +1.5 EV
        exposureFilter.setValue(image, forKey: kCIInputImageKey)
        exposureFilter.setValue(clamped * 1.5, forKey: kCIInputEVKey)
        var img = exposureFilter.outputImage ?? image

        // Tone curve to lift shadows but preserve highlights.
        toneCurveFilter.setValue(img, forKey: kCIInputImageKey)
        toneCurveFilter.setValue(CIVector(x: 0.00, y: 0.00 + 0.05 * clamped), forKey: "inputPoint0")
        toneCurveFilter.setValue(CIVector(x: 0.25, y: 0.25 + 0.15 * clamped), forKey: "inputPoint1")
        toneCurveFilter.setValue(CIVector(x: 0.50, y: 0.50 + 0.08 * clamped), forKey: "inputPoint2")
        toneCurveFilter.setValue(CIVector(x: 0.75, y: 0.75 + 0.02 * clamped), forKey: "inputPoint3")
        toneCurveFilter.setValue(CIVector(x: 1.00, y: 1.00), forKey: "inputPoint4")
        if let out = toneCurveFilter.outputImage { img = out }
        return img
    }

    /// Build a soft circular mask covering the full face, fading out smoothly past the edge.
    private func buildFaceMask(extent: CGRect, faces: [CGRect]) -> CIImage {
        var mask: CIImage = CIImage(color: .black).cropped(to: extent)
        for face in faces {
            let cx = face.midX
            let cy = face.midY
            let r = max(face.width, face.height) * 0.55
            guard let gradient = CIFilter(name: "CIRadialGradient") else { continue }
            gradient.setValue(CIVector(x: cx, y: cy), forKey: "inputCenter")
            gradient.setValue(r * 0.70, forKey: "inputRadius0")
            gradient.setValue(r * 1.10, forKey: "inputRadius1")
            gradient.setValue(CIColor.white, forKey: "inputColor0")
            gradient.setValue(CIColor.black, forKey: "inputColor1")
            guard let grad = gradient.outputImage?.cropped(to: extent) else { continue }
            maxCompositingFilter.setValue(grad, forKey: kCIInputImageKey)
            maxCompositingFilter.setValue(mask, forKey: kCIInputBackgroundImageKey)
            if let combined = maxCompositingFilter.outputImage { mask = combined }
        }
        return mask
    }

    /// "Make my face look better on camera" — color-focused, NO smoothing/blur.
    /// Effects stack on top of each other and are all gated to the face area
    /// via a soft circular mask so the background stays untouched.
    ///
    /// At amount = 1.0:
    ///   • +0.5 EV exposure         — brighter complexion
    ///   • shadow-lifting tone curve — soften under-eye / under-chin darkness
    ///   • +700K warmth, -10 tint    — healthier, warmer skin tone
    ///   • +20% saturation           — more lively color
    ///   • +6% contrast              — adds a bit of "pop"
    private func applyPortraitEnhance(_ image: CIImage, faces: [CGRect], amount: Double) -> CIImage {
        let clamped = max(0, min(1, amount))
        let mask = buildFaceMask(extent: image.extent, faces: faces)

        var enhanced = image

        // 1. Exposure lift
        portraitExposureFilter.setValue(enhanced, forKey: kCIInputImageKey)
        portraitExposureFilter.setValue(0.5 * clamped, forKey: kCIInputEVKey)
        if let out = portraitExposureFilter.outputImage { enhanced = out }

        // 2. Tone curve: lift mid-shadows without blowing highlights
        portraitToneCurveFilter.setValue(enhanced, forKey: kCIInputImageKey)
        portraitToneCurveFilter.setValue(CIVector(x: 0.00, y: 0.00), forKey: "inputPoint0")
        portraitToneCurveFilter.setValue(CIVector(x: 0.25, y: 0.25 + 0.08 * clamped), forKey: "inputPoint1")
        portraitToneCurveFilter.setValue(CIVector(x: 0.50, y: 0.50 + 0.04 * clamped), forKey: "inputPoint2")
        portraitToneCurveFilter.setValue(CIVector(x: 0.75, y: 0.75), forKey: "inputPoint3")
        portraitToneCurveFilter.setValue(CIVector(x: 1.00, y: 1.00), forKey: "inputPoint4")
        if let out = portraitToneCurveFilter.outputImage { enhanced = out }

        // 3. Warmth + slight magenta lean for healthier skin
        portraitTempFilter.setValue(enhanced, forKey: kCIInputImageKey)
        portraitTempFilter.setValue(CIVector(x: CGFloat(FilterSettings.neutralTemperature), y: 0),
                                    forKey: "inputNeutral")
        portraitTempFilter.setValue(CIVector(x: CGFloat(FilterSettings.neutralTemperature + 700 * clamped),
                                             y: -10 * clamped),
                                    forKey: "inputTargetNeutral")
        if let out = portraitTempFilter.outputImage { enhanced = out }

        // 4. Saturation + contrast lift
        portraitColorFilter.setValue(enhanced, forKey: kCIInputImageKey)
        portraitColorFilter.setValue(1.0 + 0.20 * clamped, forKey: kCIInputSaturationKey)
        portraitColorFilter.setValue(1.0 + 0.06 * clamped, forKey: kCIInputContrastKey)
        portraitColorFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        if let out = portraitColorFilter.outputImage { enhanced = out }

        // 5. Blend the enhanced face area back over the original via the soft face mask.
        blendWithMaskFilter.setValue(enhanced, forKey: kCIInputImageKey)
        blendWithMaskFilter.setValue(image, forKey: kCIInputBackgroundImageKey)
        blendWithMaskFilter.setValue(mask, forKey: kCIInputMaskImageKey)
        return blendWithMaskFilter.outputImage ?? image
    }
}
