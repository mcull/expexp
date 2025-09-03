import SwiftUI
import AVFoundation

@MainActor
class CameraModel: ObservableObject {
    private let captureService = CaptureService()
    
    @Published var isAuthorized = false
    @Published var isSessionRunning = false
    @Published var capturedImage: UIImage?
    @Published var showAlert = false
    @Published var alertMessage = ""
    
    var previewSource: PreviewSource {
        captureService
    }
    
    func initialize() async {
        isAuthorized = await captureService.isAuthorized
        
        if isAuthorized {
            do {
                try await captureService.setUpSession()
                await captureService.start()
                isSessionRunning = true
            } catch {
                alertMessage = "Failed to set up camera: \(error.localizedDescription)"
                showAlert = true
            }
        } else {
            alertMessage = "Camera access denied. Please enable camera access in Settings."
            showAlert = true
        }
    }
    
    func capturePhoto() {
        Task {
            do {
                let image = try await captureService.capturePhoto()
                capturedImage = image
            } catch {
                alertMessage = "Failed to capture photo: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }
    
    func switchCamera() {
        Task {
            do {
                try await captureService.switchCamera()
            } catch {
                alertMessage = "Failed to switch camera: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }
    
    func savePhoto() {
        guard let image = capturedImage else { return }
        
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(saveCompleted(_:didFinishSavingWithError:contextInfo:)), nil)
    }
    
    @objc private func saveCompleted(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let error = error {
            alertMessage = "Failed to save photo: \(error.localizedDescription)"
        } else {
            alertMessage = "Photo saved successfully!"
            capturedImage = nil
        }
        showAlert = true
    }
    
    func dismissCapturedImage() {
        capturedImage = nil
    }
}