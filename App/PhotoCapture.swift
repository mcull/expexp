import AVFoundation
import UIKit

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
        let settings: AVCapturePhotoSettings
        
        // Use HEIF/HEVC format if available for better quality and smaller file sizes
        if output.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        
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
        
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            continuation.resume(throwing: CameraError.captureSessionNotRunning)
            return
        }
        
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