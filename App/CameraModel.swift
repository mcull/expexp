import SwiftUI
import AVFoundation
import Photos

@MainActor
class CameraModel: ObservableObject {
    private let captureService = CaptureService()
    private let photoLibraryService = PhotoLibraryService()
    
    @Published var isAuthorized = false
    @Published var isSessionRunning = false
    @Published var capturedImage: UIImage?
    @Published var capturedPhoto: AVCapturePhoto?
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
                let (image, photo) = try await captureService.capturePhotoWithRawData()
                capturedImage = image
                capturedPhoto = photo
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
        guard let photo = capturedPhoto else { return }
        
        Task {
            do {
                try await photoLibraryService.savePhoto(photo)
                alertMessage = "Photo saved successfully!"
                capturedImage = nil
                capturedPhoto = nil
            } catch {
                alertMessage = "Failed to save photo: \(error.localizedDescription)"
            }
            showAlert = true
        }
    }
    
    func dismissCapturedImage() {
        capturedImage = nil
        capturedPhoto = nil
    }
}