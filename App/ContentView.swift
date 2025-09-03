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
                ZStack {
                    // Fullscreen live preview
                    CameraPreviewView(session: model.controller.session)
                        .ignoresSafeArea()

                    // Frozen image overlay (WYSIWYG display)
                    if let img = frozenImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                    }

                    // Letterbox overlays to create a centered 4:3 viewfinder
                    let frameHeight = min(size.width * 4.0/3.0, size.height)
                    let vPad = max(0, (size.height - frameHeight) / 2)
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
        SaveManager.save(img) { ok, err in
            if ok { alertMessage = "Saved to Photos"; frozenImage = nil }
            else { alertMessage = err?.localizedDescription ?? "Save failed" }
            showAlert = true
        }
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

