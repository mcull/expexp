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
                            Image(systemName: "square.and.arrow.down")
                                .font(.title)
                                .foregroundColor(cameraModel.capturedImage != nil ? .white : .gray)
                        }
                        .disabled(cameraModel.capturedImage == nil)
                    }
                    .padding(.bottom, 50)
                }
                
                if let image = cameraModel.capturedImage {
                    VStack {
                        HStack {
                            Button("Dismiss") {
                                cameraModel.dismissCapturedImage()
                            }
                            .foregroundColor(.white)
                            .padding()
                            
                            Spacer()
                        }
                        
                        Spacer()
                        
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 300, maxHeight: 400)
                            .cornerRadius(10)
                        
                        Spacer()
                        
                        HStack(spacing: 40) {
                            Button("Retake") {
                                cameraModel.dismissCapturedImage()
                            }
                            .foregroundColor(.white)
                            .padding()
                            
                            Button("Save") {
                                cameraModel.savePhoto()
                            }
                            .foregroundColor(.white)
                            .padding()
                        }
                        .padding(.bottom, 50)
                    }
                    .background(Color.black.opacity(0.8))
                    .ignoresSafeArea()
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
