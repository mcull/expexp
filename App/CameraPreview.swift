import SwiftUI
import AVFoundation
import UIKit

class PreviewView: UIView, PreviewTarget {
    
    var onTapToFocus: ((CGPoint) -> Void)?
    private var focusIndicatorView: UIView?
    
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTapGesture()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTapGesture()
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
    }
}

struct CameraPreview: UIViewRepresentable {
    
    private let source: PreviewSource
    let onTapToFocus: ((CGPoint) -> Void)?
    
    init(source: PreviewSource, onTapToFocus: ((CGPoint) -> Void)? = nil) {
        self.source = source
        self.onTapToFocus = onTapToFocus
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