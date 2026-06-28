import SwiftUI
import AVFoundation
import Photos
import UIKit
import CoreImage
import Vision

@MainActor
class CameraModel: ObservableObject {
    private let captureService = CaptureService()
    private let photoLibraryService = PhotoLibraryService()
    var previewView: PreviewView?

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?
    
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
    
    // Save-time alignment flag (Vision). When enabled, align subsequent images to the first capture
    // using Apple Vision (translation → homography) before blending.
    @Published var isAlignmentEnabled: Bool = true
    @Published var showAlert = false
    @Published var alertMessage = ""
    
    // Recently saved asset info for deeplink/thumbnail feedback
    @Published var recentSavedThumbnail: UIImage?
    @Published var showSavedThumbnail: Bool = false
    private var recentSavedLocalIdentifier: String?
    
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
                await setUpRotationCoordinator()
            } catch {
                alertMessage = "Failed to set up camera: \(error.localizedDescription)"
                showAlert = true
            }
        } else {
            alertMessage = "Camera access denied. Please enable camera access in Settings."
            showAlert = true
        }
    }

    /// Creates a RotationCoordinator for the active camera + preview layer and keeps the
    /// preview and photo-output rotation angles up to date. Safe to call again after a
    /// camera switch; it rebuilds the coordinator and observations.
    func setUpRotationCoordinator() async {
        guard let previewLayer = previewView?.previewLayer,
              let device = await captureService.activeDevice else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        await applyCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)

        previewAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                      options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.applyPreviewAngle(angle) }
        }
        captureAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                      options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in await self?.applyCaptureAngle(angle) }
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        guard let connection = previewView?.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private func applyCaptureAngle(_ angle: CGFloat) async {
        await captureService.applyCaptureGeometry(rotationAngle: angle)
    }

    func capturePhoto() {
        Task {
            do {
                let (image, photo) = try await captureService.capturePhotoWithRawData()
                print("📷 DEBUG: Captured raw image with size: \(image.size), orientation: \(image.imageOrientation.displayName)")

                // Store raw image for final processing
                capturedRawImages.append(image)
                capturedPhotos.append(photo)

                // Frames are already upright (rotation handled at capture time).
                ghostPreviewImages.append(image)
                // Update overlay (optionally with Vision alignment) for live preview
                updateGhostPreviewOverlay()

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
                await setUpRotationCoordinator()
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
                
                // Frames are captured upright; no rotation needed.
                let processedImages = capturedRawImages

                // Blend multiple images into one if we have more than one
                let finalImage: UIImage
                if processedImages.count == 1 {
                    finalImage = processedImages[0]
                    print("🖼️ DEBUG: Single upright image saved as-is")
                } else {
                    var imagesForBlend = processedImages
                    if isAlignmentEnabled {
                        print("🧭 ALIGN: Aligning \(processedImages.count - 1) images to reference using Vision...")
                        let reference = processedImages[0]
                        var aligned: [UIImage] = [reference]
                        for (idx, img) in processedImages.dropFirst().enumerated() {
                            let options = AlignmentOptions(preferHomography: true,
                                                           enableVisionPrealign: true,
                                                           enableLocalRefine: false,
                                                           downscaleTargetMP: 1.5,
                                                           timeBudgetMS: 250,
                                                           useAppleVision: true)
                            let res = AlignmentEngine.shared.align(moving: img, reference: reference, options: options)
                            aligned.append(res.alignedImage)
                            print("🧭 ALIGN: #\(idx+2) model=\(res.transformModel) runtime=\(res.metrics.runtimeMS)ms")
                        }
                        imagesForBlend = aligned
                    }
                    print("🖼️ DEBUG: Blending \(imagesForBlend.count) images (aligned: \(isAlignmentEnabled))...")
                    finalImage = blendImages(imagesForBlend)
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

    // MARK: - Live Ghost Preview Alignment
    private func updateGhostPreviewOverlay() {
        guard let canvasSize = previewView?.previewLayer.bounds.size, canvasSize.width > 0, canvasSize.height > 0 else {
            // Fallback: draw originals
            previewView?.updateGhostImages(ghostPreviewImages, opacity: CGFloat(1.0 - ghostOpacity))
            return
        }

        // Scale all ghosts to preview canvas
        let scaled = ghostPreviewImages.map { scaleImage($0, toAspectFill: canvasSize) }

        guard isAlignmentEnabled else {
            previewView?.updateGhostImages(scaled, opacity: CGFloat(1.0 - ghostOpacity))
            return
        }

        guard let first = scaled.first else {
            previewView?.updateGhostImages([], opacity: CGFloat(1.0 - ghostOpacity))
            return
        }

        // Align subsequent images to the first using Vision (translation only) at preview scale
        var aligned: [UIImage] = [first]
        for img in scaled.dropFirst() {
            if let a = translationalAlignPreview(moving: img, reference: first) {
                aligned.append(a)
            } else {
                aligned.append(img)
            }
        }
        previewView?.updateGhostImages(aligned, opacity: CGFloat(1.0 - ghostOpacity))
    }

    private func scaleImage(_ image: UIImage, toAspectFill canvasSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { ctx in
            let imgSize = image.size
            let s = max(canvasSize.width / imgSize.width, canvasSize.height / imgSize.height)
            let w = imgSize.width * s
            let h = imgSize.height * s
            let x = (canvasSize.width - w) / 2
            let y = (canvasSize.height - h) / 2
            image.draw(in: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    // Use Vision translational registration for fast, robust preview alignment in top-left coords
    private func translationalAlignPreview(moving: UIImage, reference: UIImage) -> UIImage? {
        guard let refCG = reference.cgImage, let movCG = moving.cgImage else { return nil }
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: movCG, options: [:])
        let handler = VNImageRequestHandler(cgImage: refCG, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let t = obs.alignmentTransform
        // Convert Vision bottom-left translation to top-left: (tx, -ty)
        let tx = t.tx
        let ty = -t.ty
        let size = reference.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            // Draw moving shifted by (tx, ty) in top-left coordinates
            moving.draw(in: CGRect(origin: CGPoint(x: tx, y: ty), size: moving.size))
        }
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
        guard let first = images.first else { return UIImage() }
        guard images.count > 1 else { return first }

        let canvasSize = first.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = first.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let drawRect = CGRect(origin: .zero, size: canvasSize)

        return renderer.image { ctx in
            ctx.cgContext.clear(drawRect)
            // Lighten blend with per-exposure alpha, matching the live preview compositor.
            // UIImage.draw handles image orientation correctly (no manual rotation needed).
            for image in images {
                image.draw(in: drawRect, blendMode: .lighten, alpha: CGFloat(ghostExposureAlpha))
            }
        }
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
