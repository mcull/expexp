import AVFoundation
import UIKit

final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "expexp.camera.queue")
    private let photoOutput = AVCapturePhotoOutput()

    var onPhoto: ((UIImage) -> Void)?

    func configure() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Reset inputs
            self.session.inputs.forEach { self.session.removeInput($0) }

            // Back wide camera 1x
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                self.session.commitConfiguration(); return
            }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = 1.0
                device.unlockForConfiguration()
            } catch {}

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
            } catch { print("Input error: \(error)") }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }

            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func capture() {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.isHighResolutionPhotoEnabled = true
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { print("Capture error: \(error)"); return }
        guard let data = photo.fileDataRepresentation(), let img = UIImage(data: data) else { return }
        onPhoto?(img)
    }
}

