import SwiftUI
import AVFoundation
import UIKit

class PreviewView: UIView, PreviewTarget {
    
    var onTapToFocus: ((CGPoint) -> Void)?
    private var focusIndicatorView: UIView?
    
    // Single composite overlay to avoid per-layer alpha differences
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
        ghostContainerLayer.addSublayer(ghostCompositeLayer)
    }
    
    // Update overlay images to match preview layer's sizing and gravity exactly
    func updateGhostImages(_ images: [UIImage], opacity: CGFloat) {
        // Build a single lighten-blended composite, then apply overall opacity
        if let composite = composeLightenComposite(from: images) {
            ghostCompositeLayer.contents = composite.cgImage
        } else {
            ghostCompositeLayer.contents = nil
        }
        ghostCompositeLayer.opacity = Float(max(0, min(1, opacity)))
        ghostCompositeLayer.contentsGravity = previewLayer.videoGravity.layerGravity
        ghostCompositeLayer.frame = ghostContainerLayer.bounds
    }

    // Creates a single image by stacking with lighten blend, similar to save path
    private func composeLightenComposite(from images: [UIImage]) -> UIImage? {
        guard let first = images.first else { return nil }
        let canvasSize = first.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = first.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let img = renderer.image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: canvasSize))
            let rect = CGRect(origin: .zero, size: canvasSize)
            for image in images {
                guard let cg = image.cgImage else { continue }
                ctx.cgContext.setBlendMode(.lighten)
                ctx.cgContext.setAlpha(0.8) // emulate save-time alpha per exposure
                ctx.cgContext.draw(cg, in: rect)
            }
        }
        return img
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
        return preview
    }
    
    func updateUIView(_ previewView: PreviewView, context: Context) {
        previewView.onTapToFocus = onTapToFocus
    }
}
