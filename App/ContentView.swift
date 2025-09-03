import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = CameraViewModel()
    @State private var frozenImage: UIImage?
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var focusValue: Double = 0.5

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                let size = geo.size
                // Centered 4:3 viewfinder box
                let frameWidth = size.width
                let frameHeight = min(frameWidth * 4.0/3.0, size.height)
                let vPad = max(0, (size.height - frameHeight) / 2)

                ZStack {
                    // Live preview constrained to 4:3 box
                    CameraPreviewView(session: model.controller.session) { point in
                        model.controller.focusAt(point: point)
                    }
                        .frame(width: frameWidth, height: frameHeight)
                        .clipped()
                        .position(x: size.width/2, y: size.height/2)

                    // Frozen image overlay in the same 4:3 box (WYSIWYG)
                    if let img = frozenImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: frameWidth, height: frameHeight)
                            .clipped()
                            .position(x: size.width/2, y: size.height/2)
                    }

                    // Letterbox overlays to emphasize 4:3 viewfinder
                    GeometryReader { fullGeo in
                        VStack(spacing: 0) {
                            // Top letterbox extends from very top to 4:3 viewport
                            Color.black.opacity(0.5).frame(height: (fullGeo.size.height - frameHeight) / 2)
                            Spacer(minLength: frameHeight) // 4:3 viewport area (transparent)
                            Color.black.opacity(0.5).frame(height: vPad)
                        }
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea(.all)
                }
            }

            // Controls
            VStack(spacing: 12) {
                // Manual focus slider
                HStack {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.white.opacity(0.8))
                    Slider(value: $focusValue, in: 0...1) { editing in
                        if !editing {
                            model.controller.setManualFocus(Float(focusValue))
                        }
                    }
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal)

                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.9))
                        .disabled(frozenImage == nil)
                    Spacer()
                    Button(action: { model.capture() }) {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 2))
                    }
                    Spacer()
                    // Spacer to balance layout
                    Color.clear.frame(width: 60, height: 1)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
            .background(.ultraThinMaterial)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onReceive(model.$lastPhoto.compactMap { $0 }) { img in
            // Freeze exactly what was captured; WYSIWYG overlay
            frozenImage = img
        }
        .alert("Save", isPresented: $showAlert) { Button("OK", role: .cancel) {} } message: { Text(alertMessage) }
    }

    private func save() {
        guard let img = frozenImage else { return }
        // Crop to centered 4:3 for ultra-WYSIWYG export
        let croppedImg = cropToFourThree(image: img) ?? img
        // Apply orientation from when photo was captured
        let orientedImg = croppedImg.orientedForSaving(model.lastPhotoOrientation)
        SaveManager.save(orientedImg) { ok, err in
            if ok { alertMessage = "Saved to Photos"; frozenImage = nil }
            else { alertMessage = err?.localizedDescription ?? "Save failed" }
            showAlert = true
        }
    }

    private func cropToFourThree(image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let iw = CGFloat(cg.width)
        let ih = CGFloat(cg.height)
        let targetRatio: CGFloat = 4.0/3.0 // height/width in portrait terms
        // We want a portrait 4:3 crop (h:w = 4:3). Compute crop rect centered.
        // Compare current h/w to target.
        let currentRatio = ih / iw
        var crop: CGRect
        if currentRatio > targetRatio {
            // Too tall: reduce height
            let ch = iw * targetRatio
            crop = CGRect(x: 0, y: (ih - ch)/2, width: iw, height: ch)
        } else {
            // Too wide: reduce width
            let cw = ih / targetRatio
            crop = CGRect(x: (iw - cw)/2, y: 0, width: cw, height: ih)
        }
        guard let cut = cg.cropping(to: crop.integral) else { return nil }
        return UIImage(cgImage: cut, scale: image.scale, orientation: image.imageOrientation)
    }
}

private extension UIImage {
    func orientedForSaving(_ deviceOrientation: UIDeviceOrientation) -> UIImage {
        // Actually rotate the image pixels based on device orientation
        let rotationAngle: CGFloat
        
        switch deviceOrientation {
        case .portrait:
            rotationAngle = 0 // No rotation for portrait - works correctly
        case .landscapeLeft:
            rotationAngle = CGFloat.pi / 2 // 90 degrees clockwise (was 180°)
        case .landscapeRight:
            rotationAngle = -CGFloat.pi / 2 // 90 degrees counterclockwise (180° from previous)
        case .portraitUpsideDown:
            rotationAngle = CGFloat.pi // 180 degrees (was 90° clockwise)
        default:
            rotationAngle = 0 // Default to no rotation
        }
        
        return rotated(by: rotationAngle)
    }
    
    func rotated(by angle: CGFloat) -> UIImage {
        let rotatedSize = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: angle))
            .integral.size
        
        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, scale)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return self }
        
        let origin = CGPoint(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: angle)
        
        draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
}

final class CameraViewModel: ObservableObject {
    let controller = CameraController()
    @Published var lastPhoto: UIImage?
    @Published var lastPhotoOrientation: UIDeviceOrientation = .portrait

    init() {
        controller.onPhoto = { [weak self] img, orientation in
            DispatchQueue.main.async { 
                self?.lastPhoto = img 
                self?.lastPhotoOrientation = orientation
            }
        }
    }

    func start() { controller.configure() }
    func stop() { controller.session.stopRunning() }
    func capture() { controller.capture() }
}
