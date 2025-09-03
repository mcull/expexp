import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = CameraViewModel()
    @State private var frozenImage: UIImage?
    @State private var showAlert = false
    @State private var alertMessage = ""

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
                    CameraPreviewView(session: model.controller.session)
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
                    VStack(spacing: 0) {
                        Color.black.opacity(0.5).frame(height: vPad)
                        Spacer(minLength: 0)
                        Color.black.opacity(0.5).frame(height: vPad)
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                }
            }

            // Controls
            VStack(spacing: 12) {
                // Slider (not wired)
                HStack {
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(.white.opacity(0.8))
                    Slider(value: .constant(0.5), in: 0...1)
                    Image(systemName: "circle.righthalf.filled").foregroundStyle(.white.opacity(0.8))
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
        let export = cropToFourThree(image: img) ?? img
        SaveManager.save(export) { ok, err in
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

final class CameraViewModel: ObservableObject {
    let controller = CameraController()
    @Published var lastPhoto: UIImage?

    init() {
        controller.onPhoto = { [weak self] img in
            DispatchQueue.main.async { self?.lastPhoto = img }
        }
    }

    func start() { controller.configure() }
    func stop() { controller.session.stopRunning() }
    func capture() { controller.capture() }
}
