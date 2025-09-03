import SwiftUI
import AVFoundation
import Photos
import UIKit

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
    
    private var captureOrientation: UIDeviceOrientation = .portrait
    private var captureCamera: AVCaptureDevice.Position = .back
    
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
        // Capture the current device orientation and camera position at the moment the shutter is pressed
        captureOrientation = UIDevice.current.orientation
        
        Task {
            do {
                // Get camera position before capture
                captureCamera = await captureService.currentCameraPosition
                
                let (image, photo) = try await captureService.capturePhotoWithRawData()
                
                // Apply rotation based on device orientation and camera position at capture time
                let rotatedImage = rotateImage(image, for: captureOrientation, cameraPosition: captureCamera)
                
                capturedImage = rotatedImage
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
    
    func focusAt(point: CGPoint) {
        Task {
            do {
                try await captureService.focusAt(point: point)
            } catch {
                alertMessage = "Failed to focus: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }
    
    func savePhoto() {
        guard let photo = capturedPhoto, let image = capturedImage else { return }
        
        Task {
            do {
                // Save the rotated image that's already been processed for display
                try await photoLibraryService.saveImage(image)
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
    
    private func rotateImage(_ image: UIImage, for orientation: UIDeviceOrientation, cameraPosition: AVCaptureDevice.Position) -> UIImage {
        
        // Get the rotation angle based on device orientation and camera position
        let rotationAngle: CGFloat
        
        switch orientation {
        case .portrait:
            rotationAngle = 0 // No rotation needed
        case .portraitUpsideDown:
            rotationAngle = .pi // 180 degrees
        case .landscapeLeft:
            // For front camera, swap left and right rotations due to mirror effect
            if cameraPosition == .front {
                rotationAngle = .pi / 2 // Use right rotation for left tilt
            } else {
                rotationAngle = -.pi / 2 // Standard left rotation for rear camera
            }
        case .landscapeRight:
            // For front camera, swap left and right rotations due to mirror effect
            if cameraPosition == .front {
                rotationAngle = -.pi / 2 // Use left rotation for right tilt
            } else {
                rotationAngle = .pi / 2 // Standard right rotation for rear camera
            }
        default:
            // For unknown, faceUp, faceDown orientations, don't rotate
            rotationAngle = 0
        }
        
        // If no rotation needed, return original image
        guard rotationAngle != 0 else { return image }
        
        // Create a new image context with rotated image
        let size = image.size
        let rotatedSize: CGSize
        
        // For 90-degree rotations, swap width and height
        if abs(rotationAngle) == .pi / 2 {
            rotatedSize = CGSize(width: size.height, height: size.width)
        } else {
            rotatedSize = size
        }
        
        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, image.scale)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return image }
        
        // Move to center of the new image
        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        
        // Rotate the context
        context.rotate(by: rotationAngle)
        
        // Draw the image (centered on the rotated context)
        image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
}