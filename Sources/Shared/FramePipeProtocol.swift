import Foundation

/// Shared constants between the host app and the camera extension.
enum FramePipeIPCConstants {
    /// Bundle identifier of the camera extension (used by OSSystemExtensionRequest).
    static let extensionBundleID = "com.ghken.camtune.CameraExtension"
    /// Localized name of the virtual camera device.
    static let virtualCameraName = "camtune Virtual Camera"
}
