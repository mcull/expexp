import AVFoundation
import UIKit

class PhotoCapture: NSObject {
    let output = AVCapturePhotoOutput()
    
    func capturePhoto() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let settings = AVCapturePhotoSettings()
            
            // Only set quality prioritization if the output supports it
            if output.maxPhotoQualityPrioritization.rawValue >= AVCapturePhotoOutput.QualityPrioritization.quality.rawValue {
                settings.photoQualityPrioritization = .quality
            } else {
                settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
            }
            
            let delegate = PhotoCaptureDelegate(continuation: continuation)
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let continuation: CheckedContinuation<UIImage, Error>
    
    init(continuation: CheckedContinuation<UIImage, Error>) {
        self.continuation = continuation
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            continuation.resume(throwing: error)
            return
        }
        
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else {
            continuation.resume(throwing: CameraError.captureSessionNotRunning)
            return
        }
        
        continuation.resume(returning: image)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            continuation.resume(throwing: error)
        }
    }
}