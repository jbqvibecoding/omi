import AppKit
import AVFoundation

/// Captures a single JPEG frame from the default webcam, mirroring ScreenCaptureManager's
/// stateless static API so the output is drop-in for the existing image pipeline. Used by
/// the watcher `$CAMERA` sensor. The capture session is spun up on demand and torn down
/// immediately after one frame — nothing keeps the camera live.
enum CameraCaptureManager {
    /// Returns JPEG data for one webcam frame, or nil if unavailable / not permitted.
    static func captureCameraJPEG(quality: CGFloat = 0.7) async -> Data? {
        guard await ensureAuthorized() else {
            log("CameraCaptureManager: camera permission not granted, skipping capture")
            return nil
        }
        guard let cgImage = await captureOneFrame() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            log("CameraCaptureManager: JPEG encoding failed")
            return nil
        }
        log("CameraCaptureManager: captured \(cgImage.width)x\(cgImage.height), JPEG \(data.count / 1024) KB")
        return data
    }

    // MARK: - Authorization (mirrors AudioCaptureService, .video)

    private static func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - One-shot capture

    private static func captureOneFrame() async -> CGImage? {
        guard let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            log("CameraCaptureManager: no camera device / input")
            return nil
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let delegate = SingleFrameGrabber()
        let queue = DispatchQueue(label: "camera.capture.queue")
        output.setSampleBufferDelegate(delegate, queue: queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)

        session.startRunning()
        // Give the camera a moment to warm up and deliver a frame.
        let image = await delegate.firstFrame(timeout: 2.0)
        session.stopRunning()
        session.removeOutput(output)
        session.removeInput(input)
        return image
    }
}

/// Grabs the first delivered sample buffer and converts it to a CGImage.
private final class SingleFrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var delivered = false

    func firstFrame(timeout: TimeInterval) async -> CGImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)
        finish(cgImage)
    }

    private func finish(_ image: CGImage?) {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered, let cont = continuation else { return }
        delivered = true
        continuation = nil
        cont.resume(returning: image)
    }
}
