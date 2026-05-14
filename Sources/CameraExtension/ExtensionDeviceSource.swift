import Foundation
import CoreMediaIO
import CoreVideo
import CoreImage
import CoreGraphics
import CoreText

/// Owns and coordinates the source and sink streams.
/// Pattern mirrors OBS's `OBSCameraDeviceSource`:
///   - A "placeholder" timer that emits a test pattern to the source stream
///     whenever the sink is NOT being fed by a host.
///   - A "consume" timer (run while host is feeding the sink) that pulls
///     CMSampleBuffers via the callback-form `consumeSampleBuffer(from:)` and
///     forwards them to the source stream.
final class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private var sourceStreamSource: ExtensionStreamSource!
    private var sinkStreamSource: ExtensionSinkStream!

    private var streamingCounter: UInt32 = 0
    private var streamingSinkCounter: UInt32 = 0

    private var placeholderTimer: DispatchSourceTimer?
    private var consumeTimer: DispatchSourceTimer?

    private let timerQueue = DispatchQueue(
        label: "camtune.ext.timer",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem,
        target: .global(qos: .userInteractive)
    )

    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!
    private var bufferAuxAttributes: NSDictionary!

    private var testPatternImage: CGImage?

    private(set) var sinkStarted = false

    private let width: Int32 = 1280
    private let height: Int32 = 720

    init(localizedName: String) {
        super.init()
        let deviceUUID = UUID(uuidString: "F4DF8E1D-49D8-44C3-8E3E-D43B0E1C6E70")!
        let sourceUUID = UUID(uuidString: "B9D5D5DA-5856-45E4-8CC8-1F8E69C7E0F1")!
        let sinkUUID = UUID(uuidString: "C7A3E4F1-66B2-49AB-9831-2D44E1C8FA66")!

        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &videoDescription
        )

        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: CFTypeRef](),
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttrs, &bufferPool)
        bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(camtuneFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(camtuneFrameRate)),
            validFrameDurations: nil
        )

        sourceStreamSource = ExtensionStreamSource(
            streamID: sourceUUID,
            streamFormat: streamFormat,
            device: device
        )
        sinkStreamSource = ExtensionSinkStream(
            streamID: sinkUUID,
            streamFormat: streamFormat,
            device: device
        )

        do {
            // Order matters: host enumerates streams and treats index 1 as sink.
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            fatalError("Failed to add streams: \(error)")
        }

        testPatternImage = renderTestPatternImage()
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionDeviceProperties
    {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = 0x76697274
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "camtune"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws { }

    // MARK: - Source stream lifecycle

    func startStreaming() {
        guard bufferPool != nil else { return }
        streamingCounter += 1

        placeholderTimer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        placeholderTimer!.schedule(
            deadline: .now(),
            repeating: 1.0 / Double(camtuneFrameRate),
            leeway: .seconds(0)
        )
        placeholderTimer!.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.sinkStarted { return }
            self.emitTestPattern()
        }
        placeholderTimer!.resume()
    }

    func stopStreaming() {
        if streamingCounter > 1 {
            streamingCounter -= 1
        } else {
            streamingCounter = 0
            if let t = placeholderTimer {
                t.cancel()
                placeholderTimer = nil
            }
        }
    }

    private func emitTestPattern() {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, bufferPool, bufferAuxAttributes, &pb
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            if let ctx = CGContext(
                data: base, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                if let img = testPatternImage {
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: videoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sb
        )
        guard let sampleBuffer = sb else { return }
        sourceStreamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(
                timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)
            )
        )
    }

    // MARK: - Sink stream lifecycle

    func startStreamingSink(client: CMIOExtensionClient) {
        streamingSinkCounter += 1
        sinkStarted = true

        consumeTimer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        // Poll at 3x frame rate (OBS pattern).
        consumeTimer!.schedule(
            deadline: .now(),
            repeating: 1.0 / (Double(camtuneFrameRate) * 3.0),
            leeway: .seconds(0)
        )
        consumeTimer!.setEventHandler { [weak self] in
            self?.consume(from: client)
        }
        consumeTimer!.resume()
    }

    func stopStreamingSink() {
        sinkStarted = false
        if streamingSinkCounter > 1 {
            streamingSinkCounter -= 1
        } else {
            streamingSinkCounter = 0
            if let t = consumeTimer {
                t.cancel()
                consumeTimer = nil
            }
        }
    }

    private func consume(from client: CMIOExtensionClient) {
        guard sinkStarted else { return }
        sinkStreamSource.stream.consumeSampleBuffer(from: client) { [weak self]
            sampleBuffer, sequenceNumber, _, _, error in
            guard let self = self else { return }
            guard let sb = sampleBuffer else { return }

            let hostNs = UInt64(
                CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC)
            )

            if self.streamingCounter > 0 {
                self.sourceStreamSource.stream.send(
                    sb,
                    discontinuity: [],
                    hostTimeInNanoseconds: UInt64(
                        sb.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)
                    )
                )
            }

            let output = CMIOExtensionScheduledOutput(
                sequenceNumber: sequenceNumber,
                hostTimeInNanoseconds: hostNs
            )
            self.sinkStreamSource.stream.notifyScheduledOutputChanged(output)
        }
    }

    // MARK: - Test pattern image

    private func renderTestPatternImage() -> CGImage? {
        let w = Int(width), h = Int(height)
        let bytesPerRow = w * 4
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75),
            (0, 0.75, 0), (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)
        ]
        let barW = CGFloat(w) / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: CGFloat(h) * 0.40,
                            width: barW, height: CGFloat(h) * 0.45))
        }

        drawText("camtune", in: ctx,
                 at: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) * 0.78),
                 fontName: "HelveticaNeue-Bold", fontSize: 80,
                 color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        drawText("ホストアプリの送信待機中", in: ctx,
                 at: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) * 0.22),
                 fontName: "HelveticaNeue", fontSize: 28,
                 color: CGColor(red: 0.8, green: 0.8, blue: 0.85, alpha: 1))
        return ctx.makeImage()
    }

    private func drawText(_ text: String, in ctx: CGContext, at point: CGPoint,
                          fontName: String, fontSize: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let attrString = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attrs as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(
            x: point.x - bounds.width / 2,
            y: point.y - bounds.height / 2
        )
        CTLineDraw(line, ctx)
    }
}
