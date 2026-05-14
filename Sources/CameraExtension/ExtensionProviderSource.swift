import Foundation
import CoreMediaIO

final class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource: ExtensionDeviceSource

    init(clientQueue: DispatchQueue?) {
        deviceSource = ExtensionDeviceSource(localizedName: FramePipeIPCConstants.virtualCameraName)
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws { }
    func disconnect(from client: CMIOExtensionClient) { }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionProviderProperties
    {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "camtune"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws { }
}
