import SwiftUI
import MetalKit
import CoreImage
import Combine

struct CameraPreviewView: NSViewRepresentable {
    let manager: CameraManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator
        context.coordinator.attach(view: view, manager: manager)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?
        private let imageLock = NSLock()
        private var currentImage: CIImage?
        private var subscription: AnyCancellable?
        private weak var view: MTKView?

        func attach(view: MTKView, manager: CameraManager) {
            self.view = view
            if let device = view.device {
                ciContext = CIContext(mtlDevice: device, options: [
                    .cacheIntermediates: false
                ])
                commandQueue = device.makeCommandQueue()
            }
            subscription = manager.processedFrames
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak view] image in
                    self?.imageLock.lock()
                    self?.currentImage = image
                    self?.imageLock.unlock()
                    view?.draw()
                }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            imageLock.lock()
            let image = currentImage
            imageLock.unlock()

            guard let image,
                  let drawable = view.currentDrawable,
                  let cq = commandQueue,
                  let ctx = ciContext,
                  let buffer = cq.makeCommandBuffer() else { return }

            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            // Mirror horizontally for selfie-style preview.
            let mirrored = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))

            // Aspect-fit
            let srcW = mirrored.extent.width
            let srcH = mirrored.extent.height
            let scale = min(drawableSize.width / srcW, drawableSize.height / srcH)
            let scaled = mirrored.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let dx = (drawableSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x
            let dy = (drawableSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y
            let positioned = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

            // Letterbox background
            let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: drawableSize))
            let composited = positioned.composited(over: background)

            ctx.render(composited,
                       to: drawable.texture,
                       commandBuffer: buffer,
                       bounds: CGRect(origin: .zero, size: drawableSize),
                       colorSpace: CGColorSpaceCreateDeviceRGB())

            buffer.present(drawable)
            buffer.commit()
        }
    }
}
