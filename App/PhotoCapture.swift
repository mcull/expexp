import AVFoundation
import UIKit
import CoreImage

class PhotoCapture: NSObject {
    let output = AVCapturePhotoOutput()
    private var activeDelegate: PhotoCaptureDelegate?
    
    func capturePhoto() async throws -> UIImage {
        let (image, _) = try await capturePhotoWithRawData()
        return image
    }
    
    func capturePhotoWithRawData() async throws -> (UIImage, AVCapturePhoto) {
        try await withCheckedThrowingContinuation { continuation in
            let settings = createPhotoSettings()
            let delegate = PhotoCaptureDelegate(continuation: continuation) { [weak self] in
                self?.activeDelegate = nil
            }
            self.activeDelegate = delegate
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }
    
    private func createPhotoSettings() -> AVCapturePhotoSettings {
        // Use uncompressed format for better blending - this preserves full image data
        let settings = AVCapturePhotoSettings(format: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        
        print("📸 DEBUG: Using uncompressed BGRA format for better blending")
        
        // Enable automatic flash
        settings.flashMode = .auto
        
        // Enable image stabilization if supported
        settings.isAutoStillImageStabilizationEnabled = output.isStillImageStabilizationSupported
        
        // Only set quality prioritization if the output supports it
        if output.maxPhotoQualityPrioritization.rawValue >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue {
            settings.photoQualityPrioritization = .quality
        } else {
            settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
        }
        
        return settings
    }
}

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<(UIImage, AVCapturePhoto), Error>
    private let cleanup: () -> Void
    private var hasResumed = false
    
    init(continuation: CheckedContinuation<(UIImage, AVCapturePhoto), Error>, cleanup: @escaping () -> Void) {
        self.continuation = continuation
        self.cleanup = cleanup
        super.init()
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard !hasResumed else { return }
        hasResumed = true
        
        defer { cleanup() }
        
        if let error = error {
            continuation.resume(throwing: error)
            return
        }
        
        // Try to get image from pixel buffer first (for uncompressed format)
        if let pixelBuffer = photo.pixelBuffer {
            print("📸 DEBUG: Extracting image from pixel buffer (uncompressed)")
            let image = UIImage.fromPixelBuffer(pixelBuffer)
            continuation.resume(returning: (image, photo))
            return
        }
        
        // Fallback to compressed data if pixel buffer not available
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            print("📸 DEBUG: Failed to get image data from photo")
            continuation.resume(throwing: CameraError.captureSessionNotRunning)
            return
        }
        
        print("📸 DEBUG: Using compressed image data as fallback")
        continuation.resume(returning: (image, photo))
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !hasResumed else { return }
        
        if let error = error {
            hasResumed = true
            continuation.resume(throwing: error)
            cleanup()
        }
    }
}

extension UIImage {
    static func fromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> UIImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("📸 DEBUG: Failed to create CGImage from pixel buffer")
            return UIImage()
        }
        
        print("📸 DEBUG: Successfully created UIImage from pixel buffer, size: \(CGSize(width: cgImage.width, height: cgImage.height))")
        return UIImage(cgImage: cgImage)
    }
}