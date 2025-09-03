import SwiftUI
import AVFoundation
import Photos
import UIKit
import CoreImage

@MainActor
class CameraModel: ObservableObject {
    private let captureService = CaptureService()
    private let photoLibraryService = PhotoLibraryService()
    var previewView: PreviewView?
    
    @Published var isAuthorized = false
    @Published var isSessionRunning = false
    @Published var capturedPhotos: [AVCapturePhoto] = []
    private var capturedRawImages: [UIImage] = []  // Store raw unprocessed images
    @Published var ghostPreviewImages: [UIImage] = []  // Processed images for ghost preview
    @Published var ghostOpacity: Double = 0.5 {        // Control ghost preview opacity
        didSet {
            // Only adjust opacity; avoid recomposing for smoother slider performance
            previewView?.setGhostOpacity(CGFloat(1.0 - ghostOpacity))
        }
    }
    
    /// Per-exposure alpha used for both preview and save-time lighten blends.
    /// Keeping this configurable ensures the live preview closely matches the final export.
    @Published var ghostExposureAlpha: Double = 0.8 {
        didSet {
            // Update preview's exposure alpha and recompose with existing images
            previewView?.setExposureAlpha(CGFloat(ghostExposureAlpha), currentImages: ghostPreviewImages)
        }
    }
    @Published var showAlert = false
    @Published var alertMessage = ""
    
    // Recently saved asset info for deeplink/thumbnail feedback
    @Published var recentSavedThumbnail: UIImage?
    @Published var showSavedThumbnail: Bool = false
    private var recentSavedLocalIdentifier: String?

    // Recently saved thumbnail for subtle feedback instead of alerts
    @Published var recentSavedThumbnail: UIImage?
    @Published var showSavedThumbnail: Bool = false
    
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
                
                // Store raw image for final processing
                capturedRawImages.append(image)
                capturedPhotos.append(photo)
                
                // Rotate ghost to match camera preview orientation  
                let rotatedGhost = rotateImageClockwise(image)
                ghostPreviewImages.append(rotatedGhost)
                // Update overlay within the preview layer to ensure perfect alignment
                previewView?.updateGhostImages(ghostPreviewImages, opacity: CGFloat(1.0 - ghostOpacity))
                print("📷 DEBUG: Ghost image size: \(rotatedGhost.size), scale: \(rotatedGhost.scale) (rotated to match preview)")
                
                print("📷 DEBUG: Total captured images: \(capturedRawImages.count) (raw + \(ghostPreviewImages.count) ghost previews)")
                
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
                // Refresh overlay mirroring to match new camera connection
                previewView?.refreshMirroring()
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
                    // Align behavior with multi-exposure path: apply the same 90° clockwise
                    // correction so single-portrait captures are not saved rotated CCW.
                    if let cg = processedImages[0].cgImage {
                        let rotated = rotateCGImageClockwise(cg)
                        finalImage = UIImage(cgImage: rotated, scale: processedImages[0].scale, orientation: .up)
                        print("🖼️ DEBUG: Single image rotated 90° clockwise for consistent orientation")
                    } else {
                        finalImage = processedImages[0]
                        print("🖼️ DEBUG: Single image used as-is (no CGImage)")
                    }
                } else {
                    print("🖼️ DEBUG: Blending \(processedImages.count) processed images...")
                    finalImage = blendImages(processedImages)
                    print("🖼️ DEBUG: Blend complete")
                }
                
                print("🖼️ DEBUG: Final image size: \(finalImage.size)")
                
                // Save the final image and capture local identifier for deeplink
                let localId = try await photoLibraryService.saveImageReturningLocalIdentifier(finalImage)
                self.recentSavedLocalIdentifier = localId

                // Show transient thumbnail instead of success alert
                if let thumb = makeThumbnail(from: finalImage, maxSide: 64) {
                    recentSavedThumbnail = thumb
                    withAnimation(.easeOut(duration: 0.2)) {
                        showSavedThumbnail = true
                    }
                    // Hide after 3 seconds
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation(.easeIn(duration: 0.25)) {
                            self.showSavedThumbnail = false
                        }
                    }
                }

                // Clear the buffer for the next set
                capturedRawImages.removeAll()
                capturedPhotos.removeAll()
                ghostPreviewImages.removeAll()
                previewView?.updateGhostImages([], opacity: 0)
            } catch {
                alertMessage = "Failed to save photo: \(error.localizedDescription)"
                showAlert = true
            }
        }
    }

    func clearBuffer() {
        capturedRawImages.removeAll()
        capturedPhotos.removeAll()
        ghostPreviewImages.removeAll()
        previewView?.updateGhostImages([], opacity: 0)
    }

    private func makeThumbnail(from image: UIImage, maxSide: CGFloat) -> UIImage? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(maxSide / longest, 1)
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, false, 0)
        image.draw(in: CGRect(origin: .zero, size: target))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    func openPhotosApp() {
        // Best-effort: open Photos app. Apple does not provide a public deep link to a specific asset.
        // This opens the app (typically to Library/Recents where the image appears).
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
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
        
        // Start with transparent background for ghostly layering
        context.clear(CGRect(origin: .zero, size: canvasSize))
        
        let drawRect = CGRect(origin: .zero, size: canvasSize)
        
        // Option 1: Lighten blend mode - keeps saturation, creates ghostly overlaps
        // This brightens where images overlap while preserving colors
        for (index, image) in images.enumerated() {
            guard let cgImage = image.cgImage else {
                print("🎨 DEBUG: Failed to get CGImage from image \(index)")
                continue
            }
            
            // Use lighten blend mode for ghostly effect with full saturation
            context.setBlendMode(.lighten)
            // Slight transparency per exposure; configurable to match preview
            context.setAlpha(CGFloat(ghostExposureAlpha))
            context.draw(cgImage, in: drawRect)
            print("🎨 DEBUG: Drew image \(index + 1) with lighten blend mode, alpha: \(ghostExposureAlpha)")
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
        
        // Apply 90° counterclockwise rotation transform
        context.translateBy(x: 0, y: CGFloat(width))
        context.rotate(by: -.pi / 2)  // 90° counterclockwise
        
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
    
    private func rotateImageClockwise(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
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
            return image
        }
        
        // Apply 90° counterclockwise rotation transform
        context.translateBy(x: 0, y: CGFloat(width))
        context.rotate(by: -.pi / 2)  // 90° counterclockwise
        
        // Draw the original image in the rotated context
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let rotatedCGImage = context.makeImage() else {
            return image
        }
        
        return UIImage(cgImage: rotatedCGImage, scale: image.scale, orientation: .up)
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
