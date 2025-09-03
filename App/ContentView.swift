import SwiftUI

struct ContentView: View {
    @StateObject private var cameraModel = CameraModel()
    
    var body: some View {
        ZStack {
            if cameraModel.isAuthorized && cameraModel.isSessionRunning {
                CameraPreview(source: cameraModel.previewSource) { focusPoint in
                    cameraModel.focusAt(point: focusPoint)
                }
                .ignoresSafeArea()
                
                VStack {
                    Spacer()
                    
                    HStack(spacing: 40) {
                        Button(action: cameraModel.switchCamera) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title)
                                .foregroundColor(.white)
                        }
                        
                        Button(action: cameraModel.capturePhoto) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 70, height: 70)
                                .overlay(
                                    Circle()
                                        .stroke(Color.black.opacity(0.1), lineWidth: 2)
                                )
                        }
                        
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
                    }
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
