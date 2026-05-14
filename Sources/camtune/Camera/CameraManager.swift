@preconcurrency import AVFoundation
import CoreImage
import Combine
import Foundation

final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
    private static let lastDeviceIDKey = "camtune.lastCameraDeviceID"

    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var permissionGranted: Bool = false
    @Published private(set) var statusMessage: String = "初期化中…"

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "camtune.video.queue", qos: .userInteractive)
    private let pipeline: FilterPipeline
    private let processedSubject = PassthroughSubject<CIImage, Never>()
    private let rawSubject = PassthroughSubject<CIImage, Never>()
    private var outputAttached = false  // videoQueue 専有

    var processedFrames: AnyPublisher<CIImage, Never> {
        processedSubject.eraseToAnyPublisher()
    }

    /// Raw (pre-filter) frames straight from the camera, for preset preview
    /// thumbnail rendering.
    var rawFrames: AnyPublisher<CIImage, Never> {
        rawSubject.eraseToAnyPublisher()
    }

    init(pipeline: FilterPipeline) {
        self.pipeline = pipeline
        super.init()
    }

    func start() async {
        let granted = await requestCameraPermission()
        await MainActor.run {
            self.permissionGranted = granted
            if !granted {
                self.statusMessage = "カメラへのアクセスが拒否されています。システム設定 > プライバシーで許可してください。"
            }
        }
        guard granted else { return }

        let initialID: String? = await MainActor.run {
            self.refreshDevices()
            if self.selectedDeviceID == nil {
                self.selectedDeviceID = self.pickInitialDeviceID()
            }
            return self.selectedDeviceID
        }

        guard let deviceID = initialID else {
            await MainActor.run { self.statusMessage = "利用可能なカメラが見つかりません" }
            return
        }

        videoQueue.async { [weak self] in
            guard let self else { return }
            self.applyConfiguration(deviceID: deviceID)
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async { self.statusMessage = "稼働中" }
        }
    }

    func stop() {
        videoQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    /// UI からのデバイス切替エントリポイント。
    func selectDevice(id: String) {
        DispatchQueue.main.async {
            guard self.selectedDeviceID != id else { return }
            self.selectedDeviceID = id
            UserDefaults.standard.set(id, forKey: Self.lastDeviceIDKey)
        }
        videoQueue.async { [weak self] in
            self?.applyConfiguration(deviceID: id)
        }
    }

    /// Pick the initial camera device, preferring (in order):
    /// 1. The device the user picked in a previous session (if still present)
    /// 2. The first non-virtual camera (avoid the camtune Virtual Camera
    ///    feedback loop)
    /// 3. The first available device
    private func pickInitialDeviceID() -> String? {
        if let savedID = UserDefaults.standard.string(forKey: Self.lastDeviceIDKey),
           availableDevices.contains(where: { $0.uniqueID == savedID }) {
            return savedID
        }
        if let nonVirtual = availableDevices.first(where: {
            $0.localizedName != FramePipeIPCConstants.virtualCameraName
        }) {
            return nonVirtual.uniqueID
        }
        return availableDevices.first?.uniqueID
    }

    // MARK: - Private

    /// Must run on videoQueue.
    private func applyConfiguration(deviceID: String) {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            DispatchQueue.main.async { self.statusMessage = "デバイスが見つかりません" }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        for input in session.inputs {
            session.removeInput(input)
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusMessage = "このカメラはセッションに追加できません"
                }
                return
            }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.statusMessage = "カメラを開けません: \(error.localizedDescription)"
            }
            return
        }

        if !outputAttached {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                outputAttached = true
            }
        }

        session.commitConfiguration()
    }

    private func refreshDevices() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        availableDevices = discovery.devices
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        rawSubject.send(input)
        let output = pipeline.process(input)
        processedSubject.send(output)
    }
}
