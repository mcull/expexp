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
                    HStack(spacing: 14) {
                        iconButton("arrow.triangle.2.circlepath.camera", action: cameraModel.switchCamera)
                            .opacity(0.85)
                        if let thumb = cameraModel.recentSavedThumbnail {
                            Button(action: cameraModel.openPhotosApp) {
                                Image(uiImage: thumb)
                                    .resizable().scaledToFill()
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.85), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    Spacer()
                    saveButton
                        .opacity(cameraModel.hasStack ? 1 : 0)
                        .allowsHitTesting(cameraModel.hasStack)
                }
                .padding(.horizontal, 28)

                ZStack {
                    ShutterButton(showsPlus: cameraModel.hasStack, action: cameraModel.capturePhoto)
                    if cameraModel.isAlignmentEnabled && cameraModel.hasStack {
                        LevelReticle(lock: cameraModel.lockMonitor)
                    }
                }
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

/// Plain white shutter with a `+` once a stack is in progress.
private struct ShutterButton: View {
    let showsPlus: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
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

/// Flight-sim level reticle around the shutter: a bubble drifts off-center as the device rotates
/// away from the first-frame orientation and settles into the center target when matched. The
/// sight banks with roll. Honest rotation hint (not a "lock") — taps pass through to the shutter.
private struct LevelReticle: View {
    @ObservedObject var lock: LockMonitor
    private let travel: CGFloat = 44   // max bubble offset from center (points)
    private var locked: Bool { lock.isCentered }
    private var lockGreen: Color { Color(red: 0.45, green: 0.95, blue: 0.6) }

    var body: some View {
        ZStack {
            // Sight ring + 4 ticks, banked by roll. Ring turns green when fully matched (bubble
            // centered AND sight upright).
            ZStack {
                Circle()
                    .stroke(locked ? lockGreen : .white.opacity(0.22), lineWidth: locked ? 1.5 : 1)
                    .frame(width: 100, height: 100)
                    .shadow(color: locked ? lockGreen.opacity(0.7) : .clear, radius: 7)
                ForEach(0..<4, id: \.self) { i in
                    Rectangle().fill(locked ? lockGreen : .white.opacity(0.4)).frame(width: 2, height: 8)
                        .offset(y: -50).rotationEffect(.degrees(Double(i) * 90))
                }
            }
            .rotationEffect(.radians(-lock.roll))
            .animation(.easeOut(duration: 0.15), value: locked)

            // Center target.
            Circle().stroke(locked ? lockGreen : .white.opacity(0.3), lineWidth: 1)
                .frame(width: 22, height: 22)

            // Bubble.
            Circle().fill(locked ? lockGreen : .white.opacity(0.9))
                .frame(width: 12, height: 12)
                .shadow(color: locked ? lockGreen.opacity(0.8) : .clear, radius: 6)
                .offset(x: lock.levelOffset.width * travel, y: lock.levelOffset.height * travel)
                .animation(.easeOut(duration: 0.12), value: lock.levelOffset)
        }
        .allowsHitTesting(false)
    }
}
