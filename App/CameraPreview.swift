import SwiftUI
import AVFoundation
import UIKit

class PreviewView: UIView, PreviewTarget {
    
    var onTapToFocus: ((CGPoint) -> Void)?
    private var focusIndicatorView: UIView?
    
    // Single composite overlay to avoid per-layer alpha differences
    private let ghostContainerLayer = CALayer()
    private let ghostCompositeLayer = CALayer()
    
    // Configurable per-exposure opacity used during preview composition.
    // This emulates the save-time lighten blend so the slider matches the final look.
    var ghostExposureAlpha: CGFloat = 0.8
    
    // Cache to avoid redundant recomposition and reduce CPU churn
    private var currentGhostImageCount: Int = 0
    private var cachedCompositeImage: CGImage?
    
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
        // Preserve vertical flip on layout resets
        ghostCompositeLayer.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
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
        // Fix vertical mirroring by flipping the composite layer vertically
        ghostCompositeLayer.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
        ghostContainerLayer.addSublayer(ghostCompositeLayer)
    }
    
    // Update overlay images to match preview layer's sizing and gravity exactly
    func updateGhostImages(_ images: [UIImage], opacity: CGFloat) {
        // Recompose only if image count changed or no cache yet
        if images.count != currentGhostImageCount || cachedCompositeImage == nil {
            if let composite = composeLightenComposite(from: images) {
                cachedCompositeImage = composite.cgImage
            } else {
                cachedCompositeImage = nil
            }
            currentGhostImageCount = images.count
        }
        ghostCompositeLayer.contents = cachedCompositeImage
        ghostCompositeLayer.opacity = Float(max(0, min(1, opacity)))
        ghostCompositeLayer.contentsGravity = previewLayer.videoGravity.layerGravity
        ghostCompositeLayer.frame = ghostContainerLayer.bounds
    }

    // Fast path: only change opacity without recomposing
    func setGhostOpacity(_ opacity: CGFloat) {
        ghostCompositeLayer.opacity = Float(max(0, min(1, opacity)))
    }

    // Exposure alpha changed; recompose using existing images if any
    func setExposureAlpha(_ alpha: CGFloat, currentImages: [UIImage]) {
        ghostExposureAlpha = alpha
        // Force recomposition next update
        cachedCompositeImage = nil
        updateGhostImages(currentImages, opacity: CGFloat(ghostCompositeLayer.opacity))
    }

    // Creates a single image by stacking with lighten blend, similar to save path
    private func composeLightenComposite(from images: [UIImage]) -> UIImage? {
        guard !images.isEmpty else { return nil }
        // Render at preview size for performance; fall back to first image size if not laid out yet
        let fallback = images[0].size
        let canvasSize = ghostContainerLayer.bounds.size == .zero ? fallback : ghostContainerLayer.bounds.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let img = renderer.image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: canvasSize))
            // Draw each image aspect-fill into the canvas
            for image in images {
                guard let cg = image.cgImage else { continue }
                ctx.cgContext.setBlendMode(.lighten)
                // Use configurable per-exposure alpha so preview matches save-time blend
                ctx.cgContext.setAlpha(ghostExposureAlpha)
                let drawRect = aspectFillRect(forImageSize: CGSize(width: cg.width, height: cg.height), inCanvas: canvasSize)
                ctx.cgContext.draw(cg, in: drawRect)
            }
        }
        return img
    }

    private func aspectFillRect(forImageSize imageSize: CGSize, inCanvas canvasSize: CGSize) -> CGRect {
        let scale = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = (canvasSize.width - width) / 2
        let y = (canvasSize.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
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
        // Initialize preview's per-exposure alpha to match model setting
        preview.ghostExposureAlpha = CGFloat(cameraModel.ghostExposureAlpha)
        return preview
    }
    
    func updateUIView(_ previewView: PreviewView, context: Context) {
        previewView.onTapToFocus = onTapToFocus
    }
}
