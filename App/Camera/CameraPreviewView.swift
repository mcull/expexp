import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onTapToFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        v.onTapToFocus = onTapToFocus
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.onTapToFocus = onTapToFocus
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTapToFocus: ((CGPoint) -> Void)?
        
        override func awakeFromNib() {
            super.awakeFromNib()
            setupGestures()
        }
        
        override func layoutSubviews() {
            super.layoutSubviews()
            if gestureRecognizers?.isEmpty ?? true {
                setupGestures()
            }
        }
        
        private func setupGestures() {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            addGestureRecognizer(tapGesture)
        }
        
        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: self)
            let convertedPoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            onTapToFocus?(convertedPoint)
            
            // Show focus indicator animation
            showFocusIndicator(at: location)
        }
        
        private func showFocusIndicator(at point: CGPoint) {
            let focusView = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
            focusView.center = point
            focusView.layer.borderColor = UIColor.yellow.cgColor
            focusView.layer.borderWidth = 2
            focusView.backgroundColor = UIColor.clear
            focusView.alpha = 0
            
            addSubview(focusView)
            
            UIView.animate(withDuration: 0.3, animations: {
                focusView.alpha = 1
                focusView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            }) { _ in
                UIView.animate(withDuration: 0.5, delay: 0.5, animations: {
                    focusView.alpha = 0
                }) { _ in
                    focusView.removeFromSuperview()
                }
            }
        }
    }
}

