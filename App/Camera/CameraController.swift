import AVFoundation
import UIKit
import CoreMotion

final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "expexp.camera.queue")
    private let photoOutput = AVCapturePhotoOutput()
    private let motionManager = CMMotionManager()

    var onPhoto: ((UIImage, UIDeviceOrientation) -> Void)?
    private var videoDevice: AVCaptureDevice?
    
    private var deviceOrientation: UIDeviceOrientation {
        if let accelerometerData = motionManager.accelerometerData {
            let x = accelerometerData.acceleration.x
            let y = accelerometerData.acceleration.y
            
            if abs(x) > abs(y) {
                return x > 0 ? .landscapeLeft : .landscapeRight
            } else {
                return y > 0 ? .portraitUpsideDown : .portrait
            }
        }
        return .portrait
    }

    func configure() {
        // Start accelerometer for orientation detection
        if motionManager.isAccelerometerAvailable {
            motionManager.startAccelerometerUpdates()
        }
        
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Reset inputs
            self.session.inputs.forEach { self.session.removeInput($0) }

            // Back wide camera 1x
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                self.session.commitConfiguration(); return
            }
            self.videoDevice = device
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
                if #available(iOS 16.0, *) {
                    self.photoOutput.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                } else {
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                }
            }

            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func capture() {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
    
    func focusAt(point: CGPoint) {
        guard let device = videoDevice,
              device.isFocusPointOfInterestSupported,
              device.isFocusModeSupported(.autoFocus) else { return }
        
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
                
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                
                device.unlockForConfiguration()
            } catch {
                print("Focus error: \(error)")
            }
        }
    }
    
    func setManualFocus(_ value: Float) {
        guard let device = videoDevice,
              device.isFocusModeSupported(.locked) else { return }
        
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: value, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                print("Manual focus error: \(error)")
            }
        }
    }
    
    func getCurrentDeviceOrientation() -> UIDeviceOrientation {
        return deviceOrientation
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error { print("Capture error: \(error)"); return }
        guard let data = photo.fileDataRepresentation(), 
              let img = UIImage(data: data) else { return }
        
        // Capture the orientation at the moment of capture
        let captureOrientation = deviceOrientation
        
        // For display: normalize to match viewfinder orientation
        let displayImg = img.normalizedForViewfinder()
        onPhoto?(displayImg, captureOrientation)
    }
}

private extension UIImage {
    // For displaying in the frozen overlay - always normalize to upright
    func normalizedForViewfinder() -> UIImage {
        if imageOrientation == .up { return self }
        
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return normalizedImage ?? self
    }
    
    // For saving - apply device orientation to match how user held phone
    func orientedForSaving(_ deviceOrientation: UIDeviceOrientation) -> UIImage {
        // Actually rotate the image pixels based on device orientation
        let rotationAngle: CGFloat
        
        switch deviceOrientation {
        case .portrait:
            rotationAngle = 0 // No rotation for portrait - works correctly
        case .landscapeLeft:
            rotationAngle = CGFloat.pi / 2 // 90 degrees clockwise (was 180°)
        case .landscapeRight:
            rotationAngle = -CGFloat.pi / 2 // 90 degrees counterclockwise (180° from previous)
        case .portraitUpsideDown:
            rotationAngle = CGFloat.pi // 180 degrees (was 90° clockwise)
        default:
            rotationAngle = 0 // Default to no rotation
        }
        
        return rotated(by: rotationAngle)
    }
    
    func rotated(by angle: CGFloat) -> UIImage {
        let rotatedSize = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: angle))
            .integral.size
        
        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return self }
        
        let origin = CGPoint(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: angle)
        
        draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
}

