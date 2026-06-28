import SwiftUI
import AVFoundation
import UIKit

class PreviewView: UIView, PreviewTarget {
    
    var onTapToFocus: ((CGPoint) -> Void)?
    private var focusIndicatorView: UIView?
    
    // Single composite overlay layer; CameraModel composites the image and hands it here.
    private let ghostContainerLayer = CALayer()
    private let ghostCompositeLayer = CALayer()

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTapGesture()
        setupGhostContainer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTapGesture()
        setupGhostContainer()
    }
    
    private func setupTapGesture() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)
    }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let tapPoint = gesture.location(in: self)
        
        // Convert tap point to device coordinates
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: tapPoint)
        
        // Show focus indicator
        showFocusIndicator(at: tapPoint)
        
        // Call focus callback
        onTapToFocus?(devicePoint)
    }
    
    private func showFocusIndicator(at point: CGPoint) {
        // Remove existing focus indicator
        focusIndicatorView?.removeFromSuperview()
        
        // Create focus indicator view (yellow square)
        let indicatorSize: CGFloat = 80
        let indicator = UIView(frame: CGRect(
            x: point.x - indicatorSize/2,
            y: point.y - indicatorSize/2,
            width: indicatorSize,
            height: indicatorSize
        ))
        
        indicator.layer.borderWidth = 2
        indicator.layer.borderColor = UIColor.systemYellow.cgColor
        indicator.backgroundColor = UIColor.clear
        indicator.alpha = 0
        
        addSubview(indicator)
        focusIndicatorView = indicator
        
        // Animate the focus indicator
        UIView.animate(withDuration: 0.2, animations: {
            indicator.alpha = 1.0
        }) { _ in
            UIView.animate(withDuration: 0.5, delay: 0.8, animations: {
                indicator.alpha = 0
            }) { _ in
                indicator.removeFromSuperview()
                if self.focusIndicatorView == indicator {
                    self.focusIndicatorView = nil
                }
            }
        }
    }
    
    func setSession(_ session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        // Ensure overlay container tracks the preview bounds and gravity
        ghostContainerLayer.frame = previewLayer.bounds
        ghostContainerLayer.masksToBounds = true
    }
    
    func capturePreviewSnapshot() -> UIImage? {
        // Capture only the video preview layer, not the entire view
        guard let contents = previewLayer.contents else { return nil }
        
        let layerBounds = previewLayer.bounds
        UIGraphicsBeginImageContextWithOptions(layerBounds.size, false, 0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // Create a temporary layer to render the contents
        let tempLayer = CALayer()
        tempLayer.frame = CGRect(origin: .zero, size: layerBounds.size)
        tempLayer.contents = contents
        tempLayer.contentsGravity = previewLayer.videoGravity.layerGravity
        tempLayer.render(in: context)
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep ghost container and composite layer in sync with preview layer bounds
        ghostContainerLayer.frame = previewLayer.bounds
        ghostCompositeLayer.frame = ghostContainerLayer.bounds
        // Preserve flips on layout resets (vertical always, horizontal if preview is mirrored)
        applyCompositeTransform()
    }
    
    private func setupGhostContainer() {
        ghostContainerLayer.frame = bounds
        ghostContainerLayer.masksToBounds = true
        // Place above the video preview
        previewLayer.addSublayer(ghostContainerLayer)
        
        // Configure composite layer
        ghostCompositeLayer.frame = ghostContainerLayer.bounds
        ghostCompositeLayer.masksToBounds = true
        ghostCompositeLayer.contentsGravity = previewLayer.videoGravity.layerGravity
        ghostCompositeLayer.opacity = 0
        ghostCompositeLayer.contentsScale = UIScreen.main.scale
        // Apply initial flips to match preview (vertical flip; add horizontal if mirrored)
        applyCompositeTransform()
        ghostContainerLayer.addSublayer(ghostCompositeLayer)
    }
    
    /// Display a pre-composited overlay image (built by CameraModel via ExposureCompositor).
    func setOverlayImage(_ image: UIImage?, opacity: CGFloat) {
        ghostCompositeLayer.contents = image?.cgImage
        ghostCompositeLayer.opacity = Float(max(0, min(1, opacity)))
        ghostCompositeLayer.contentsGravity = .resizeAspectFill
        ghostCompositeLayer.frame = ghostContainerLayer.bounds
    }

    /// Fast path: change only the opacity without recompositing.
    func setGhostOpacity(_ opacity: CGFloat) {
        ghostCompositeLayer.opacity = Float(max(0, min(1, opacity)))
    }

    private func applyCompositeTransform() {
        // Frames are captured upright and front-camera frames are mirrored to match the
        // preview, so the ghost composite needs no extra flip. Kept as the single tuning
        // point for overlay orientation.
        ghostCompositeLayer.setAffineTransform(.identity)
    }

    // Public hook to refresh mirroring when camera changes
    func refreshMirroring() {
        applyCompositeTransform()
    }
}

extension AVLayerVideoGravity {
    var layerGravity: CALayerContentsGravity {
        switch self {
        case .resizeAspectFill: return .resizeAspectFill
        case .resizeAspect: return .resizeAspect
        case .resize: return .resize
        default: return .resizeAspectFill
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    
    private let source: PreviewSource
    let onTapToFocus: ((CGPoint) -> Void)?
    let onCaptureSnapshot: ((UIImage?) -> Void)?
    
    init(source: PreviewSource, onTapToFocus: ((CGPoint) -> Void)? = nil, onCaptureSnapshot: ((UIImage?) -> Void)? = nil) {
        self.source = source
        self.onTapToFocus = onTapToFocus
        self.onCaptureSnapshot = onCaptureSnapshot
    }
    
    func makeUIView(context: Context) -> PreviewView {
        let preview = PreviewView()
        preview.onTapToFocus = onTapToFocus
        source.connect(to: preview)
        // Keep preview's per-exposure alpha consistent with model defaults if used
        return preview
    }
    
    func updateUIView(_ previewView: PreviewView, context: Context) {
        previewView.onTapToFocus = onTapToFocus
    }
}

struct CameraPreviewWithModel: UIViewRepresentable {
    
    let cameraModel: CameraModel
    let onTapToFocus: ((CGPoint) -> Void)?
    
    func makeUIView(context: Context) -> PreviewView {
        let preview = PreviewView()
        preview.onTapToFocus = onTapToFocus
        cameraModel.previewSource.connect(to: preview)
        cameraModel.previewView = preview  // Store reference
        // Now that the preview layer exists, (re)build the RotationCoordinator. The call in
        // initialize() can run before this view is created, so the coordinator would otherwise
        // never apply its angles or front-camera mirroring.
        Task { await cameraModel.setUpRotationCoordinator() }
        return preview
    }
    
    func updateUIView(_ previewView: PreviewView, context: Context) {
        previewView.onTapToFocus = onTapToFocus
    }
}
