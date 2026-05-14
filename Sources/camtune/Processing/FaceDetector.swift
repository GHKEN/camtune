import Vision
import CoreImage
import Foundation

/// Throttled face rectangle detector. Returns the most recently detected face
/// boxes in CIImage extent coordinate space (origin bottom-left, in pixels).
final class FaceDetector {
    private let queue = DispatchQueue(label: "camtune.face.detection", qos: .userInitiated)
    private let lock = NSLock()
    private var _faces: [CGRect] = []
    private var inFlight = false
    private var lastRunAt: TimeInterval = 0
    private let minInterval: TimeInterval = 0.2  // ~5 fps

    var faces: [CGRect] {
        lock.lock(); defer { lock.unlock() }
        return _faces
    }

    /// Schedule a detection if cooldown elapsed and no other request is in flight.
    /// Must be called on the video queue; detection itself runs off-thread.
    func detectIfNeeded(in image: CIImage) {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        guard !inFlight, now - lastRunAt > minInterval else {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()

        let extent = image.extent
        // CIImage is value-typed wrt the underlying pixel buffer — safe to send.
        let snapshot = image
        queue.async { [weak self] in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(ciImage: snapshot, orientation: .up, options: [:])
            var boxes: [CGRect] = []
            do {
                try handler.perform([request])
                if let results = request.results {
                    boxes = results.map { obs -> CGRect in
                        // VNFaceObservation.boundingBox is normalized (0..1), origin bottom-left.
                        let bb = obs.boundingBox
                        return CGRect(
                            x: bb.minX * extent.width + extent.minX,
                            y: bb.minY * extent.height + extent.minY,
                            width: bb.width * extent.width,
                            height: bb.height * extent.height
                        )
                    }
                }
            } catch {
                // Detection failed (e.g., model unavailable); leave previous result in place.
            }
            guard let self else { return }
            self.lock.lock()
            self._faces = boxes
            self.lastRunAt = Date().timeIntervalSinceReferenceDate
            self.inFlight = false
            self.lock.unlock()
        }
    }
}
