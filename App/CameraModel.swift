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
    private var capturedImages: [UIImage] = []
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
                if capturedImages.isEmpty {
                    captureOrientation = UIDevice.current.orientation
                    captureCamera = await captureService.currentCameraPosition
                    print("📷 DEBUG: First capture - orientation: \(captureOrientation), camera: \(captureCamera)")
                }
                
                let (image, photo) = try await captureService.capturePhotoWithRawData()
                print("📷 DEBUG: Captured image with size: \(image.size)")
                
                // Apply rotation based on device orientation and camera position from first capture
                let rotatedImage = rotateImage(image, for: captureOrientation, cameraPosition: captureCamera)
                print("📷 DEBUG: Rotated image size: \(rotatedImage.size)")
                
                // Add to arrays instead of replacing
                capturedImages.append(rotatedImage)
                capturedPhotos.append(photo)
                
                print("📷 DEBUG: Total captured images: \(capturedImages.count)")
                
                // Verify we're getting different images
                if capturedImages.count > 1 {
                    let currentImage = rotatedImage
                    let previousImage = capturedImages[capturedImages.count - 2]
                    if currentImage.pngData() == previousImage.pngData() {
                        print("🚨 DEBUG: WARNING - Current image identical to previous image!")
                    } else {
                        print("✅ DEBUG: Current image differs from previous - good for blending")
                    }
                }
                
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
        guard !capturedImages.isEmpty else { return }
        
        Task {
            do {
                print("🖼️ DEBUG: Starting save process with \(capturedImages.count) images")
                print("🖼️ DEBUG: Individual image sizes: \(capturedImages.map { $0.size })")
                
                // Blend multiple images into one if we have more than one
                let finalImage: UIImage
                if capturedImages.count == 1 {
                    finalImage = capturedImages[0]
                    print("🖼️ DEBUG: Using single image (no blending needed)")
                } else {
                    print("🖼️ DEBUG: Blending \(capturedImages.count) images...")
                    finalImage = blendImages(capturedImages)
                    print("🖼️ DEBUG: Blend complete, checking if result differs from individual images")
                    
                    // Verify we actually got a blended result by checking object identity
                    if let lastImage = capturedImages.last {
                        if finalImage === lastImage {
                            print("🚨 DEBUG: CRITICAL - Final image is the SAME OBJECT as last captured image!")
                        } else {
                            print("✅ DEBUG: Final image is different object - blending created new image")
                            
                            // Additional check - compare a few pixel values instead of full PNG data
                            let finalCGImage = finalImage.cgImage
                            let lastCGImage = lastImage.cgImage
                            if finalCGImage === lastCGImage {
                                print("🚨 DEBUG: WARNING - Final image shares same CGImage as last image")
                            } else {
                                print("✅ DEBUG: Final image has different CGImage - blending worked!")
                            }
                        }
                    }
                }
                
                print("🖼️ DEBUG: Final image size: \(finalImage.size)")
                
                // Save the blended image
                try await photoLibraryService.saveImage(finalImage)
                alertMessage = capturedImages.count == 1 ? "Photo saved successfully!" : "Multiple exposure saved successfully!"
                
                // Clear the buffer for the next set
                capturedImages.removeAll()
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
        
        // Fill with black background for multiple exposure effect
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        
        // Draw each image with screen blend mode
        let drawRect = CGRect(origin: .zero, size: canvasSize)
        
        for (index, image) in images.enumerated() {
            guard let cgImage = image.cgImage else {
                print("🎨 DEBUG: Failed to get CGImage from image \(index)")
                continue
            }
            
            // Use screen blend mode for multiple exposure effect
            context.setBlendMode(.screen)
            context.draw(cgImage, in: drawRect)
            print("🎨 DEBUG: Drew image \(index + 1) with screen blend mode")
        }
        
        guard let blendedCGImage = context.makeImage() else {
            print("🎨 DEBUG: Failed to create final blended CGImage")
            return firstImage
        }
        
        // Create UIImage with correct orientation (up since we already rotated the images)
        let blendedImage = UIImage(cgImage: blendedCGImage, scale: firstImage.scale, orientation: .up)
        print("🎨 DEBUG: Created blended image with \(images.count) exposures, orientation: .up")
        return blendedImage
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