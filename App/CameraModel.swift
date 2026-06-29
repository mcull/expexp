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
    /// Latest preview rotation angle (degrees). 90 = portrait baseline. Used to rotate the ghost
    /// overlay so it visually matches the live (horizon-leveled) preview when held in landscape.
    private var lastPreviewAngle: CGFloat = 90

    /// Capture rotation angle locked to the first exposure of the current stack, so every
    /// exposure shares one orientation (portrait or landscape) and blends cleanly. Nil when
    /// no stack is in progress; reset on save/clear so the next stack picks a fresh orientation.
    private var lockedCaptureAngle: CGFloat?

    /// Alignment of each captured frame relative to frame 0 (parallel to capturedRawImages).
    private var transforms: [FrameAlignment] = []
    /// Active camera position, used to pick the alignment anchor.
    private var captureCameraPosition: AVCaptureDevice.Position = .back
    /// Anchor: front camera freezes the face (selfie swirl); back camera freezes the scene.
    private var currentAnchor: AlignmentAnchor {
        captureCameraPosition == .front ? .face : .scene
    }
    /// Briefly true when a just-captured frame could not be aligned (Magic on).
    @Published var showAlignmentWarning: Bool = false

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
            updateGhostPreviewOverlay()
        }
    }
    
    // Magic alignment toggle. ON aligns subsequent frames to the first via AlignmentService;
    // OFF stacks frames exactly as shot. Both are WYSIWYG (preview == save).
    @Published var isAlignmentEnabled: Bool = true {
        didSet {
            recomputeTransforms()
            updateGhostPreviewOverlay()
        }
    }
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
                captureCameraPosition = await captureService.currentCameraPosition
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
        // Drive the photo off the PREVIEW angle so the captured photo matches how the phone is
        // held (portrait→portrait, landscape→landscape). The "capture" horizon-level angle is
        // always landscape, which produced landscape photos even in portrait.
        await applyCaptureAngle(lockedCaptureAngle ?? coordinator.videoRotationAngleForHorizonLevelPreview)

        previewAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                      options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in
                guard let self else { return }
                self.applyPreviewAngle(angle)
                // Capture follows the device too, unless a stack has locked its orientation.
                if self.lockedCaptureAngle == nil {
                    await self.applyCaptureAngle(angle)
                }
            }
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        lastPreviewAngle = angle
        if let connection = previewView?.previewLayer.connection,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        // Re-rotate the ghost overlay to keep matching the (now possibly rotated) live preview.
        updateGhostPreviewOverlay()
    }

    private func applyCaptureAngle(_ angle: CGFloat) async {
        await captureService.applyCaptureGeometry(rotationAngle: angle)
    }

    func capturePhoto() {
        Task {
            do {
                // Lock the stack's orientation to the first exposure's physical orientation,
                // then apply it for every shot so the whole stack stays portrait or landscape.
                if capturedRawImages.isEmpty {
                    lockedCaptureAngle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview
                }
                if let angle = lockedCaptureAngle {
                    await applyCaptureAngle(angle)
                }

                let (image, photo) = try await captureService.capturePhotoWithRawData()
                print("📷 DEBUG: Captured raw image with size: \(image.size), orientation: \(image.imageOrientation.displayName)")

                // Store raw image for final processing
                capturedRawImages.append(image)
                capturedPhotos.append(photo)
                ghostPreviewImages.append(image)

                // Compute this frame's alignment relative to the first (reference) frame.
                if capturedRawImages.count == 1 {
                    transforms = [.identity]
                } else if isAlignmentEnabled, let reference = capturedRawImages.first {
                    let a = AlignmentService.alignment(moving: image, reference: reference, anchor: currentAnchor)
                    transforms.append(a)
                    if !a.locked { flashAlignmentWarning() }
                } else {
                    transforms.append(.identity)
                }

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
                captureCameraPosition = await captureService.currentCameraPosition
                recomputeTransforms()
                updateGhostPreviewOverlay()
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
                
                let finalImage: UIImage
                if capturedRawImages.count == 1 {
                    finalImage = capturedRawImages[0]
                    print("🖼️ DEBUG: Single upright image saved as-is")
                } else if let canvas = capturedRawImages.first?.size,
                          let composite = ExposureCompositor.composite(frames: capturedRawImages,
                                                                       alignments: transforms,
                                                                       canvasSize: canvas,
                                                                       scale: 1,
                                                                       exposureAlpha: CGFloat(ghostExposureAlpha)) {
                    finalImage = composite
                    print("🖼️ DEBUG: Composited \(capturedRawImages.count) frames (aligned: \(isAlignmentEnabled))")
                } else {
                    finalImage = capturedRawImages[0]
                    print("🖼️ DEBUG: Composite failed; saved first frame")
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
                transforms.removeAll()
                lockedCaptureAngle = nil  // next stack picks a fresh orientation
                previewView?.setOverlayImage(nil, opacity: 0)
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
        transforms.removeAll()
        lockedCaptureAngle = nil  // next stack picks a fresh orientation
        previewView?.setOverlayImage(nil, opacity: 0)
    }

    // MARK: - Live Ghost Preview Alignment

    private func updateGhostPreviewOverlay() {
        guard let bounds = previewView?.previewLayer.bounds.size, bounds.width > 0, bounds.height > 0 else {
            previewView?.setOverlayImage(nil, opacity: 0)
            return
        }
        // Degrees the overlay must rotate to match the live preview. The portrait baseline is
        // camera-specific: the back lens reports 90 in portrait, the front lens reports 0 (their
        // sensors are mounted 90° apart). Subtracting the baseline yields 0 in portrait and ±90
        // in landscape for both lenses.
        let portraitBaseline: CGFloat = (captureCameraPosition == .front) ? 0 : 90
        let delta = lastPreviewAngle - portraitBaseline
        let quarterTurned = (Int(delta.rounded()) % 180 + 180) % 180 == 90
        // Build the composite in the device's display orientation, then rotate it for the
        // portrait-locked overlay layer so it lines up with the rotated live feed.
        let canvas = quarterTurned ? CGSize(width: bounds.height, height: bounds.width) : bounds
        let composite = ExposureCompositor.composite(frames: ghostPreviewImages,
                                                     alignments: transforms,
                                                     canvasSize: canvas,
                                                     scale: UIScreen.main.scale,
                                                     exposureAlpha: CGFloat(ghostExposureAlpha))
        let display = composite.flatMap { rotatedForPreview($0, degrees: delta) }
        previewView?.setOverlayImage(display, opacity: CGFloat(1.0 - ghostOpacity))
    }

    /// Rotates an image by a multiple of 90° (for matching the live preview orientation).
    private func rotatedForPreview(_ image: UIImage, degrees: CGFloat) -> UIImage {
        let norm = ((Int(degrees.rounded()) % 360) + 360) % 360
        guard norm != 0 else { return image }
        let radians = CGFloat(norm) * .pi / 180
        let swap = (norm == 90 || norm == 270)
        let newSize = swap ? CGSize(width: image.size.height, height: image.size.width) : image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: newSize, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cg.rotate(by: radians)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }

    private func flashAlignmentWarning() {
        withAnimation(.easeOut(duration: 0.15)) { showAlignmentWarning = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeIn(duration: 0.25)) { self.showAlignmentWarning = false }
        }
    }

    /// Recomputes all alignments (identity when Magic is off). Used when the toggle changes.
    private func recomputeTransforms() {
        guard let reference = capturedRawImages.first else { transforms = []; return }
        var result: [FrameAlignment] = [.identity]
        for img in capturedRawImages.dropFirst() {
            if isAlignmentEnabled {
                result.append(AlignmentService.alignment(moving: img, reference: reference, anchor: currentAnchor))
            } else {
                result.append(.identity)
            }
        }
        transforms = result
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
