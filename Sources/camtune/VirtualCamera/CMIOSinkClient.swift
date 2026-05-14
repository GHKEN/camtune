import Foundation
import CoreMediaIO
import CoreVideo
import os

private let sinkLogger = Logger(subsystem: "com.ghken.camtune", category: "sink-client")

/// Discovers the camtune Virtual Camera's sink stream via CMIO and enqueues
/// processed CMSampleBuffers into its input queue. Modeled on OBS's
/// `virtualcam_output_start` flow.
final class CMIOSinkClient {
    private(set) var connected: Bool = false
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOObjectID = 0
    private var queue: CMSimpleQueue?

    func connect() -> Bool {
        guard let dev = findDeviceByName(FramePipeIPCConstants.virtualCameraName) else {
            sinkLogger.notice("connect: device '\(FramePipeIPCConstants.virtualCameraName, privacy: .public)' not found")
            return false
        }
        deviceID = dev
        sinkLogger.notice("connect: found device id=\(dev, privacy: .public)")

        // Enumerate streams of the device. The extension adds the source stream
        // first, then the sink. Host should pick the SECOND (index 1).
        let streams = enumerateStreams(of: dev)
        sinkLogger.notice("connect: device has \(streams.count, privacy: .public) streams: \(streams, privacy: .public)")
        guard streams.count >= 2 else {
            sinkLogger.error("connect: expected at least 2 streams (source + sink)")
            return false
        }
        let sinkStream = streams[1]
        sinkStreamID = sinkStream
        sinkLogger.notice("connect: selected sink stream id=\(sinkStream, privacy: .public)")

        var alteredQueue: Unmanaged<CMSimpleQueue>?
        let copyResult = CMIOStreamCopyBufferQueue(
            sinkStream,
            { _, _, _ in /* queue altered (intentionally empty) */ },
            nil,
            &alteredQueue
        )
        guard copyResult == noErr, let q = alteredQueue?.takeRetainedValue() else {
            sinkLogger.error("connect: CMIOStreamCopyBufferQueue failed result=\(copyResult, privacy: .public)")
            return false
        }
        queue = q

        let startResult = CMIODeviceStartStream(dev, sinkStream)
        guard startResult == noErr else {
            sinkLogger.error("connect: CMIODeviceStartStream failed result=\(startResult, privacy: .public)")
            return false
        }
        sinkLogger.notice("connect: sink stream started OK")
        connected = true
        return true
    }

    func disconnect() {
        if connected {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        connected = false
        queue = nil
        deviceID = 0
        sinkStreamID = 0
    }

    private var enqueueCount: UInt64 = 0
    private var enqueueErrorCount: UInt64 = 0
    private var consecutiveErrors: UInt32 = 0
    private let maxConsecutiveErrors: UInt32 = 30  // ~1 sec at 30fps

    /// Returns `true` while the connection still looks healthy; `false` if the
    /// caller (VirtualCameraOutput) should drop & reconnect because the queue
    /// has been refusing samples for too long (typically the extension was
    /// reinstalled and our queue handle is now stale).
    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let queue = queue else { return false }
        let unmanaged = Unmanaged.passRetained(sampleBuffer)
        let ptr = unmanaged.toOpaque()
        let res = CMSimpleQueueEnqueue(queue, element: ptr)
        enqueueCount &+= 1
        if res != noErr {
            unmanaged.release()
            enqueueErrorCount &+= 1
            consecutiveErrors &+= 1
            if enqueueErrorCount % 60 == 1 {
                sinkLogger.notice("enqueue err count=\(self.enqueueErrorCount, privacy: .public) latest=\(res, privacy: .public)")
            }
            if consecutiveErrors >= maxConsecutiveErrors {
                sinkLogger.notice("enqueue: \(self.consecutiveErrors, privacy: .public) consecutive errors — stale queue, forcing reconnect")
                disconnect()
                return false
            }
        } else {
            consecutiveErrors = 0
            if enqueueCount % 120 == 1 {
                sinkLogger.notice("enqueue ok #\(self.enqueueCount, privacy: .public)")
            }
        }
        return true
    }

    // MARK: - CMIO discovery

    private func findDeviceByName(_ name: String) -> CMIOObjectID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        let sizeRes = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size
        )
        guard sizeRes == noErr, size > 0 else {
            sinkLogger.error("findDevice: dataSize failed res=\(sizeRes, privacy: .public) size=\(size, privacy: .public)")
            return nil
        }

        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var actualSize = size
        let getRes = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size,
            &actualSize, &devices
        )
        guard getRes == noErr else {
            sinkLogger.error("findDevice: getData failed res=\(getRes, privacy: .public)")
            return nil
        }

        sinkLogger.notice("findDevice: enumerating \(count, privacy: .public) devices")
        for device in devices {
            let dname = deviceName(device) ?? "<nil>"
            let duid = deviceUID(device) ?? "<nil>"
            sinkLogger.notice("findDevice: device id=\(device, privacy: .public) name=\(dname, privacy: .public) uid=\(duid, privacy: .public)")
            if dname == name { return device }
        }
        return nil
    }

    private func deviceUID(_ device: CMIOObjectID) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let res = withUnsafeMutablePointer(to: &ref) { ptr -> OSStatus in
            CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &size,
                                      UnsafeMutableRawPointer(ptr))
        }
        guard res == noErr, let cfStr = ref?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    private func deviceName(_ device: CMIOObjectID) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let res = withUnsafeMutablePointer(to: &nameRef) { ptr -> OSStatus in
            CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &size,
                                      UnsafeMutableRawPointer(ptr))
        }
        guard res == noErr, let cfStr = nameRef?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    private func enumerateStreams(of device: CMIOObjectID) -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var streams = [CMIOObjectID](repeating: 0, count: count)
        var actualSize = size
        guard CMIOObjectGetPropertyData(
            device, &addr, 0, nil, size, &actualSize, &streams
        ) == noErr else { return [] }
        return streams
    }
}
