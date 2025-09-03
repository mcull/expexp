import SwiftUI

struct ContentView: View {
    @StateObject private var cameraModel = CameraModel()
    
    var body: some View {
        ZStack {
            if cameraModel.isAuthorized && cameraModel.isSessionRunning {
                CameraPreviewWithModel(cameraModel: cameraModel) { focusPoint in
                    cameraModel.focusAt(point: focusPoint)
                }
                .ignoresSafeArea()
                
                VStack {
                    Spacer()
                    
                    // Ghost opacity slider (only show if there are ghost images)
                    // Slider maps 0 (left) -> full-strength ghost composite, 1 (right) -> live camera only.
                    // The ghost composite uses lighten blend with a configurable per-exposure alpha
                    // to emulate save-time blending as closely as possible.
                    if !cameraModel.ghostPreviewImages.isEmpty {
                        VStack(spacing: 10) {
                            HStack(spacing: 15) {
                                Image(systemName: "square.stack")
                                    .font(.title3)
                                    .foregroundColor(.white)
                                
                                Slider(value: $cameraModel.ghostOpacity, in: 0...1)
                                    .accentColor(.white)
                                    .frame(width: 260)
                                
                                Image(systemName: "camera")
                                    .font(.title3)
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    
                    ZStack(alignment: .center) {
                        // Left and right control groups horizontally, centered vertically
                        HStack {
                            // Left group: flip button + transient saved thumbnail
                            ZStack(alignment: .topLeading) {
                                Button(action: cameraModel.switchCamera) {
                                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                                        .font(.title)
                                        .foregroundColor(.white)
                                }
                                if cameraModel.showSavedThumbnail, let thumb = cameraModel.recentSavedThumbnail {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 42, height: 42)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                                        )
                                        .transition(.opacity)
                                        .offset(x: -8, y: -48)
                                }
                            }
                            Spacer()
                            // Right group: save and clear
                            HStack(spacing: 16) {
                                Button(action: cameraModel.savePhoto) {
                                    ZStack {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.title)
                                            .foregroundColor(!cameraModel.capturedPhotos.isEmpty ? .white : .gray)
                                        
                                        if !cameraModel.capturedPhotos.isEmpty {
                                            Text("\(cameraModel.capturedPhotos.count)")
                                                .font(.caption)
                                                .fontWeight(.bold)
                                                .foregroundColor(.black)
                                                .background(
                                                    Circle()
                                                        .fill(Color.yellow)
                                                        .frame(width: 20, height: 20)
                                                )
                                                .offset(x: 12, y: -12)
                                        }
                                    }
                                }
                                .disabled(cameraModel.capturedPhotos.isEmpty)
                                
                                Button(action: cameraModel.clearBuffer) {
                                    Image(systemName: "xmark.circle")
                                        .font(.title)
                                        .foregroundColor(!cameraModel.capturedPhotos.isEmpty ? .white : .gray)
                                }
                                .disabled(cameraModel.capturedPhotos.isEmpty)
                                .accessibilityLabel("Clear buffer")
                            }
                        }
                        // Center: shutter button always centered horizontally
                        Button(action: cameraModel.capturePhoto) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 70, height: 70)
                                .overlay(
                                    Circle()
                                        .stroke(Color.black.opacity(0.1), lineWidth: 2)
                                )
                                .overlay(
                                    Group {
                                        if !cameraModel.capturedPhotos.isEmpty {
                                            Text("+")
                                                .font(.system(size: 28, weight: .bold))
                                                .foregroundColor(.black.opacity(0.7))
                                        }
                                    }
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 50)
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 100))
                        .foregroundColor(.gray)
                    
                    Text("Camera access required")
                        .font(.title2)
                        .foregroundColor(.gray)
                    
                    if !cameraModel.isAuthorized {
                        Text("Please enable camera access in Settings")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
        }
        .task {
            await cameraModel.initialize()
        }
        .alert("Camera", isPresented: $cameraModel.showAlert) {
            Button("OK") { }
        } message: {
            Text(cameraModel.alertMessage)
        }
    }
}
