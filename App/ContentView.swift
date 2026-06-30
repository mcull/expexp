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

                if cameraModel.showAlignmentWarning {
                    VStack {
                        Spacer().frame(height: 60)
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Couldn't lock — hold steadier")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.yellow.opacity(0.95)))
                        Spacer()
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }

                CameraControlsView(cameraModel: cameraModel)
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
