import Foundation
import CoreImage
import CoreVideo
import CoreMedia
import Combine

/// Sends processed CIImage frames to the Camera Extension via its CMIO sink
/// stream (the OBS pattern). Always-on: as soon as the host has processed
/// frames they get rendered to CMSampleBuffers and enqueued.
final class VirtualCameraOutput: ObservableObject {
    @Published private(set) var statusMessage: String = "初期化中…"
    @Published private(set) var sentFrameCount: UInt64 = 0
    @Published private(set) var connected: Bool = false

    private let ciContext: CIContext
    private let sinkClient = CMIOSinkClient()
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMFormatDescription?
    private var reconnectTimer: Timer?

    private var lastSentAt: TimeInterval = 0
    private let minInterval: TimeInterval = 1.0 / 30.0

    private let targetWidth = 1280
    private let targetHeight = 720

    init() {
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
        createPool()
        tryConnect()
        startReconnectTimerIfNeeded()
    }

    deinit {
        reconnectTimer?.invalidate()
        sinkClient.disconnect()
    }

    private func tryConnect() {
        if sinkClient.connected {
            return
        }
        if sinkClient.connect() {
            DispatchQueue.main.async {
                self.connected = true
                self.statusMessage = "送信中"
            }
            reconnectTimer?.invalidate()
            reconnectTimer = nil
        } else {
            DispatchQueue.main.async {
                self.connected = false
                self.statusMessage = "仮想カメラ未接続 (インストール待ち)"
            }
        }
    }

    private func startReconnectTimerIfNeeded() {
        guard reconnectTimer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                self?.tryConnect()
            }
        }
    }

    private func createPool() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: targetWidth,
            kCVPixelBufferHeightKey as String: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        pixelBufferPool = pool
    }

    func sendFrame(_ image: CIImage) {
        guard sinkClient.connected, let pool = pixelBufferPool else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastSentAt < minInterval { return }
        lastSentAt = now

        let srcW = image.extent.width
        let srcH = image.extent.height
        let scale = min(CGFloat(targetWidth) / srcW, CGFloat(targetHeight) / srcH)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (CGFloat(targetWidth) - scaled.extent.width) / 2 - scaled.extent.origin.x
        let dy = (CGFloat(targetHeight) - scaled.extent.height) / 2 - scaled.extent.origin.y
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let bg = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0,
                                                           width: targetWidth,
                                                           height: targetHeight))
        let composed = positioned.composited(over: bg)
            .cropped(to: CGRect(x: 0, y: 0,
                                width: targetWidth,
                                height: targetHeight))

        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let pixelBuffer = pb else { return }

        ciContext.render(composed,
                         to: pixelBuffer,
                         bounds: CGRect(x: 0, y: 0,
                                        width: targetWidth,
                                        height: targetHeight),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
        }
        guard let fd = formatDescription else { return }

        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sb
        )
        guard let sampleBuffer = sb else { return }

        let stillConnected = sinkClient.enqueue(sampleBuffer)
        if !stillConnected {
            // Queue went stale (extension was reinstalled / restarted).
            // Tear down and let the reconnect timer pick a fresh sink stream.
            DispatchQueue.main.async {
                self.connected = false
                self.statusMessage = "再接続中…"
                self.startReconnectTimerIfNeeded()
            }
            return
        }
        let count = sentFrameCount &+ 1
        DispatchQueue.main.async {
            self.sentFrameCount = count
        }
    }
}
