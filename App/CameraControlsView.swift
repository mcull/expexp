import SwiftUI

/// The cinematic bottom control cluster: exposure count, opacity, shutter + lock ring,
/// flip/save/discard, and the quiet Raw/Lock + looks controls.
struct CameraControlsView: View {
    @ObservedObject var cameraModel: CameraModel
    @State private var showOpacity = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if cameraModel.hasStack {
                ExposureCountView(count: cameraModel.capturedPhotos.count)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }

            if showOpacity && cameraModel.hasStack {
                HStack(spacing: 12) {
                    Image(systemName: "square.stack").foregroundColor(.white.opacity(0.8))
                    Slider(value: $cameraModel.ghostOpacity, in: 0...1).tint(.white)
                    Image(systemName: "camera").foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 16)
                .transition(.opacity)
            }

            // Main row: flip · shutter · save
            ZStack {
                HStack {
                    iconButton("arrow.triangle.2.circlepath.camera", action: cameraModel.switchCamera)
                        .opacity(0.85)
                    Spacer()
                    saveButton
                        .opacity(cameraModel.hasStack ? 1 : 0)
                        .allowsHitTesting(cameraModel.hasStack)
                }
                .padding(.horizontal, 28)

                ShutterButton(showsPlus: cameraModel.hasStack,
                              showRing: cameraModel.isAlignmentEnabled && cameraModel.hasStack,
                              lockProgress: cameraModel.lockProgress,
                              action: cameraModel.capturePhoto)
            }
            .padding(.bottom, 18)

            // Quiet bottom row: Raw/Lock · opacity · looks · discard
            HStack(spacing: 22) {
                Button { withAnimation { cameraModel.isAlignmentEnabled.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: cameraModel.isAlignmentEnabled ? "scope" : "circle.dashed")
                        Text(cameraModel.modeLabel).font(.footnote.weight(.semibold))
                    }
                    .foregroundColor(cameraModel.isAlignmentEnabled ? .yellow : .white.opacity(0.85))
                }

                if cameraModel.hasStack {
                    Button { withAnimation { showOpacity.toggle() } } label: {
                        Image(systemName: "slider.horizontal.below.square.filled.and.square")
                            .foregroundColor(.white.opacity(0.85))
                    }
                }

                Menu {
                    ForEach(BlendLook.allCases, id: \.self) { look in
                        Button {
                            cameraModel.blendLook = look
                        } label: {
                            Label(look.displayName, systemImage: cameraModel.blendLook == look ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundColor(.white.opacity(0.85))
                }

                if cameraModel.hasStack {
                    Button(action: cameraModel.clearBuffer) {
                        Image(systemName: "xmark.circle").foregroundColor(.white.opacity(0.85))
                    }
                    .transition(.opacity)
                }
            }
            .font(.title3)
            .padding(.bottom, 22)
        }
        .animation(.easeInOut(duration: 0.2), value: cameraModel.hasStack)
    }

    private var saveButton: some View {
        Button(action: cameraModel.savePhoto) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.green)
                if cameraModel.capturedPhotos.count > 0 {
                    Text("\(cameraModel.capturedPhotos.count)")
                        .font(.caption2).fontWeight(.bold).foregroundColor(.black)
                        .padding(4).background(Circle().fill(.white))
                        .offset(x: 8, y: -8)
                }
            }
        }
    }

    private func iconButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title).foregroundColor(.white)
        }
    }
}

/// Row of dots showing exposures taken, plus a count label.
private struct ExposureCountView: View {
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<max(count, 1), id: \.self) { _ in
                Circle().fill(.white).frame(width: 8, height: 8)
            }
            Text("\(count) exposure\(count == 1 ? "" : "s")")
                .font(.caption2).foregroundColor(.white.opacity(0.85)).padding(.leading, 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.28)))
    }
}

/// White shutter with an optional scalar lock ring (amber→green, glows solid when locked).
private struct ShutterButton: View {
    let showsPlus: Bool
    let showRing: Bool
    let lockProgress: Double
    let action: () -> Void

    private var locked: Bool { lockProgress >= 0.95 }

    var body: some View {
        Button(action: action) {
            ZStack {
                if showRing {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 4)
                        .frame(width: 84, height: 84)
                    Circle().trim(from: 0, to: max(0.02, lockProgress))
                        .stroke(locked ? Color.green : Color.yellow,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 84, height: 84)
                        .rotationEffect(.degrees(-90))
                        .shadow(color: locked ? .green.opacity(0.7) : .clear, radius: 8)
                        .animation(.easeOut(duration: 0.15), value: lockProgress)
                }
                Circle().fill(.white).frame(width: 66, height: 66)
                    .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 2))
                if showsPlus {
                    Image(systemName: "plus").font(.system(size: 26, weight: .bold))
                        .foregroundColor(.black.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
    }
}
