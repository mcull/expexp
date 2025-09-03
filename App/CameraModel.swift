import SwiftUI
import AVFoundation
import Photos
import UIKit
import CoreImage

@MainActor
class CameraModel: ObservableObject {
    private let captureService = CaptureService()
    private let photoLibraryService = PhotoLibraryService()
    
    @Published var isAuthorized = false
    @Published var isSessionRunning = false
    @Published var capturedPhotos: [AVCapturePhoto] = []
    private var capturedRawImages: [UIImage] = []  // Store raw unprocessed images
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
        Task {
            do {
                // Only capture orientation and camera position for the first image
                if capturedRawImages.isEmpty {
                    captureOrientation = UIDevice.current.orientation
                    captureCamera = await captureService.currentCameraPosition
                    print("📷 DEBUG: First capture - orientation: \(captureOrientation), camera: \(captureCamera)")
                }
                
                let (image, photo) = try await captureService.capturePhotoWithRawData()
                print("📷 DEBUG: Captured raw image with size: \(image.size), orientation: \(image.imageOrientation.displayName)")
                
                // Store raw image - NO processing during capture for speed
                capturedRawImages.append(image)
                capturedPhotos.append(photo)
                
                print("📷 DEBUG: Total captured images: \(capturedRawImages.count) (raw, unprocessed)")
                
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
        guard !capturedRawImages.isEmpty else { return }
        
        Task {
            do {
                print("🖼️ DEBUG: Starting save process with \(capturedRawImages.count) raw images")
                print("🖼️ DEBUG: Raw image sizes: \(capturedRawImages.map { $0.size })")
                
                // Process raw images (apply rotation) at save time for speed
                print("🖼️ DEBUG: Processing raw images with orientation/rotation...")
                var processedImages: [UIImage] = []
                
                for (index, rawImage) in capturedRawImages.enumerated() {
                    let shouldRotate = shouldRotateImage(rawImage, for: captureOrientation, cameraPosition: captureCamera)
                    let processedImage = shouldRotate ? rotateImage(rawImage, for: captureOrientation, cameraPosition: captureCamera) : rawImage
                    processedImages.append(processedImage)
                    print("🖼️ DEBUG: Processed image \(index + 1), rotated: \(shouldRotate)")
                }
                
                // Blend multiple images into one if we have more than one
                let finalImage: UIImage
                if processedImages.count == 1 {
                    finalImage = processedImages[0]
                    print("🖼️ DEBUG: Using single processed image (no blending needed)")
                } else {
                    print("🖼️ DEBUG: Blending \(processedImages.count) processed images...")
                    finalImage = blendImages(processedImages)
                    print("🖼️ DEBUG: Blend complete")
                }
                
                print("🖼️ DEBUG: Final image size: \(finalImage.size)")
                
                // Save the final image
                try await photoLibraryService.saveImage(finalImage)
                alertMessage = capturedRawImages.count == 1 ? "Photo saved successfully!" : "Multiple exposure saved successfully!"
                
                // Clear the buffer for the next set
                capturedRawImages.removeAll()
                capturedPhotos.removeAll()
            } catch {
                alertMessage = "Failed to save photo: \(error.localizedDescription)"
            }
            showAlert = true
        }
    }
    
    private func blendImages(_ images: [UIImage]) -> UIImage {
        print("🎨 DEBUG: Starting blend with \(images.count) images")
        
        guard let firstImage = images.first, images.count > 1 else {
            print("🎨 DEBUG: Single image, no blending needed")
            return images.first ?? UIImage()
        }
        
        print("🎨 DEBUG: Blending multiple images using screen blend mode")
        
        // Use the first image as the base canvas
        let canvasSize = firstImage.size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(data: nil,
                                    width: Int(canvasSize.width),
                                    height: Int(canvasSize.height),
                                    bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: colorSpace,
                                    bitmapInfo: bitmapInfo) else {
            print("🎨 DEBUG: Failed to create CGContext")
            return firstImage
        }
        
        // Start with transparent background for normal blending
        context.clear(CGRect(origin: .zero, size: canvasSize))
        
        // Draw each image with normal blend mode and reduced opacity
        let drawRect = CGRect(origin: .zero, size: canvasSize)
        let opacity = 1.0 / Float(images.count) // Divide opacity equally among images
        
        for (index, image) in images.enumerated() {
            guard let cgImage = image.cgImage else {
                print("🎨 DEBUG: Failed to get CGImage from image \(index)")
                continue
            }
            
            // Use normal blend mode with reduced opacity for natural multiple exposure
            context.setBlendMode(.normal)
            context.setAlpha(CGFloat(opacity))
            context.draw(cgImage, in: drawRect)
            print("🎨 DEBUG: Drew image \(index + 1) with normal blend mode, opacity: \(opacity)")
        }
        
        guard let blendedCGImage = context.makeImage() else {
            print("🎨 DEBUG: Failed to create final blended CGImage")
            return firstImage
        }
        
        // Apply 90° clockwise rotation to fix the counterclockwise rotation issue
        let rotatedCGImage = rotateCGImageClockwise(blendedCGImage)
        let blendedImage = UIImage(cgImage: rotatedCGImage, scale: firstImage.scale, orientation: .up)
        print("🎨 DEBUG: Created blended image with \(images.count) exposures, applied 90° clockwise rotation")
        return blendedImage
    }
    
    private func rotateCGImageClockwise(_ cgImage: CGImage) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        
        // Create rotated context (swap width/height for 90° rotation)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(data: nil,
                                    width: height,  // swapped
                                    height: width,  // swapped
                                    bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: colorSpace,
                                    bitmapInfo: bitmapInfo) else {
            print("🎨 DEBUG: Failed to create rotation context")
            return cgImage
        }
        
        // Apply 90° clockwise rotation transform
        context.translateBy(x: CGFloat(height), y: 0)
        context.rotate(by: .pi / 2)  // 90° clockwise
        
        // Draw the original image in the rotated context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let rotatedImage = context.makeImage() else {
            print("🎨 DEBUG: Failed to create rotated image")
            return cgImage
        }
        
        print("🎨 DEBUG: Applied 90° clockwise rotation: \(width)x\(height) -> \(height)x\(width)")
        return rotatedImage
    }
    
    private func shouldRotateImage(_ image: UIImage, for orientation: UIDeviceOrientation, cameraPosition: AVCaptureDevice.Position) -> Bool {
        print("📷 DEBUG: Checking rotation need - Device: \(orientation.rawValue), Image: \(image.imageOrientation.displayName)")
        
        // For portrait device orientation, camera typically provides .right orientation images
        // In this case, we don't need to rotate since the image is already correct for display
        if orientation == .portrait && image.imageOrientation == .right {
            print("📷 DEBUG: Portrait device + Right image orientation = No rotation needed")
            return false
        }
        
        // If device is portrait and image is already .up, also no rotation needed
        if orientation == .portrait && image.imageOrientation == .up {
            print("📷 DEBUG: Portrait device + Up image orientation = No rotation needed") 
            return false
        }
        
        // For all other combinations, apply rotation
        print("📷 DEBUG: Will apply rotation for device \(orientation.rawValue) + image \(image.imageOrientation.displayName)")
        return true
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

extension UIImage.Orientation {
    var displayName: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down" 
        case .left: return "Left"
        case .right: return "Right"
        case .upMirrored: return "Up Mirrored"
        case .downMirrored: return "Down Mirrored"
        case .leftMirrored: return "Left Mirrored"  
        case .rightMirrored: return "Right Mirrored"
        @unknown default: return "Unknown"
        }
    }
}