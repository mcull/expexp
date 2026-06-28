import AVFoundation
import UIKit
import CoreImage
import ImageIO

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
            // The pixel buffer is delivered in sensor-native orientation; the intended
            // orientation lives in the photo's metadata. Apply it so the image is upright.
            let image = UIImage.fromPixelBuffer(pixelBuffer, orientation: photo.cgImageOrientation)
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

extension AVCapturePhoto {
    /// The intended display orientation of this photo, read from its metadata.
    /// Falls back to `.up` if not present.
    var cgImageOrientation: CGImagePropertyOrientation {
        if let raw = metadata[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw) {
            return orientation
        }
        return .up
    }
}

extension UIImage.Orientation {
    /// Maps an EXIF/CGImage orientation to the semantically-equivalent UIImage orientation.
    init(_ cg: CGImagePropertyOrientation) {
        switch cg {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

extension UIImage {
    static func fromPixelBuffer(_ pixelBuffer: CVPixelBuffer,
                                orientation: CGImagePropertyOrientation = .up) -> UIImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            print("📸 DEBUG: Failed to create CGImage from pixel buffer")
            return UIImage()
        }

        // Tag the sensor-native (landscape) image with the intended orientation, then bake
        // it into upright pixels via UIKit drawing (top-left coords — avoids the CIImage
        // bottom-left .oriented() inversion). Downstream alignment uses raw .cgImage, so the
        // pixels themselves must be upright, not just orientation-tagged.
        let uiOrientation = UIImage.Orientation(orientation)
        let tagged = UIImage(cgImage: cgImage, scale: 1, orientation: uiOrientation)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: tagged.size, format: format)
        let upright = renderer.image { _ in
            tagged.draw(in: CGRect(origin: .zero, size: tagged.size))
        }

        print("📐 ORIENT: exif=\(orientation.rawValue) ui=\(uiOrientation.rawValue) baked=\(Int(upright.size.width))x\(Int(upright.size.height))")
        return upright
    }
}