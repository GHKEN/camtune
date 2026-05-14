import Foundation
import SystemExtensions
import AVFoundation
import AppKit
import Combine

/// Handles installation/uninstallation of the camtune Camera Extension.
final class ExtensionManager: NSObject, ObservableObject {
    enum Status: Equatable {
        case unknown
        case notInstalled
        case installing
        case installed
        case uninstalling
        case needsApproval
        case failed(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var lastMessage: String = ""

    private let extensionIdentifier = FramePipeIPCConstants.extensionBundleID

    // MARK: - Public API

    func refreshStatus() {
        let installed = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryTypes(),
            mediaType: .video,
            position: .unspecified
        ).devices.contains { $0.localizedName == FramePipeIPCConstants.virtualCameraName }
        DispatchQueue.main.async {
            self.status = installed ? .installed : .notInstalled
        }
    }

    func install() {
        DispatchQueue.main.async {
            self.status = .installing
            self.lastMessage = "インストールリクエスト送信中…"
        }
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        DispatchQueue.main.async {
            self.status = .uninstalling
            self.lastMessage = "アンインストール中…"
        }
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - Helpers

    /// Re-launch the host app in a fresh process so it can pick up the new
    /// Camera Extension instance (CMIO device list is cached per-process).
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL,
                                           configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func discoveryTypes() -> [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
            types.append(.deskViewCamera)
        } else {
            types.append(.externalUnknown)
        }
        return types
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction
    {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        DispatchQueue.main.async {
            self.status = .needsApproval
            self.lastMessage = "システム設定 > プライバシーとセキュリティ で承認してください"
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result)
    {
        DispatchQueue.main.async {
            switch result {
            case .completed:
                // Trust the OS — if it tells us the request completed, treat
                // the extension as installed regardless of what AVCaptureDevice
                // discovery says (it can lag for several seconds and may
                // categorize the virtual camera under an unexpected DeviceType).
                self.status = .installed
                self.lastMessage = "インストール完了 — 自動的に再起動します…"
                // The host process holds a stale CMIO device list after a
                // sysext replace; the cleanest fix is to relaunch ourselves.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.relaunchApp()
                }
            case .willCompleteAfterReboot:
                self.status = .needsApproval
                self.lastMessage = "再起動後に有効になります"
            @unknown default:
                self.status = .unknown
                self.lastMessage = "不明なステータス"
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        DispatchQueue.main.async {
            let msg = (error as? OSSystemExtensionError).map { Self.describe($0) }
                ?? error.localizedDescription
            self.status = .failed(msg)
            self.lastMessage = "失敗: \(msg)"
        }
    }

    private static func describe(_ err: OSSystemExtensionError) -> String {
        switch err.code {
        case .unknown: return "unknown"
        case .missingEntitlement: return "missingEntitlement (com.apple.developer.system-extension.install が必要)"
        case .unsupportedParentBundleLocation: return "unsupportedParentBundleLocation (.appを/Applicationsに置いて再実行が必要かも)"
        case .extensionNotFound: return "extensionNotFound (バンドル内にextensionが見つからない)"
        case .extensionMissingIdentifier: return "extensionMissingIdentifier"
        case .duplicateExtensionIdentifer: return "duplicateExtensionIdentifer"
        case .unknownExtensionCategory: return "unknownExtensionCategory"
        case .codeSignatureInvalid: return "codeSignatureInvalid (`sudo systemextensionsctl developer on` が必要)"
        case .validationFailed: return "validationFailed"
        case .forbiddenBySystemPolicy: return "forbiddenBySystemPolicy"
        case .requestCanceled: return "requestCanceled"
        case .requestSuperseded: return "requestSuperseded"
        case .authorizationRequired: return "authorizationRequired"
        @unknown default: return "rawValue=\(err.code.rawValue)"
        }
    }
}
