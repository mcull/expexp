import AVFoundation
import UIKit

enum CameraError: Error {
    case addInputFailed
    case addOutputFailed
    case captureSessionNotRunning
}

enum CaptureMode {
    case photo
    case video
}

actor CaptureService {
    nonisolated let captureSession = AVCaptureSession()
    private var activeVideoInput: AVCaptureDeviceInput?
    private let photoCapture = PhotoCapture()
    private var captureMode: CaptureMode = .photo
    
    var isAuthorized: Bool {
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var isAuthorized = status == .authorized
            if status == .notDetermined {
                isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            return isAuthorized
        }
    }
    
    func setUpSession() async throws {
        guard await isAuthorized else {
            throw CameraError.addInputFailed
        }
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Get default camera
        guard let defaultCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.addInputFailed
        }
        
        // Add camera input
        activeVideoInput = try addInput(for: defaultCamera)
        
        // Configure for photo capture
        captureSession.sessionPreset = .photo
        
        // Add photo output with enhanced configuration
        if captureSession.canAddOutput(photoCapture.output) {
            captureSession.addOutput(photoCapture.output)
            
            // Enable high resolution capture for better image quality
            photoCapture.output.isHighResolutionCaptureEnabled = true
            
            // Enable Live Photo capture if supported (for future Live Photo functionality)
            photoCapture.output.isLivePhotoCaptureEnabled = photoCapture.output.isLivePhotoCaptureSupported
        } else {
            throw CameraError.addOutputFailed
        }
    }
    
    func start() async {
        guard !captureSession.isRunning else { return }
        captureSession.startRunning()
    }
    
    func stop() {
        guard captureSession.isRunning else { return }
        captureSession.stopRunning()
    }
    
    func capturePhoto() async throws -> UIImage {
        return try await photoCapture.capturePhoto()
    }
    
    func capturePhotoWithRawData() async throws -> (UIImage, AVCapturePhoto) {
        return try await photoCapture.capturePhotoWithRawData()
    }
    
    var currentCameraPosition: AVCaptureDevice.Position {
        return activeVideoInput?.device.position ?? .back
    }
    
    func switchCamera() async throws {
        guard let currentInput = activeVideoInput else { return }
        
        let currentPosition = currentInput.device.position
        let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        
        guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
            throw CameraError.addInputFailed
        }
        
        try await changeCaptureDevice(to: newCamera)
    }
    
    @discardableResult
    private func addInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            throw CameraError.addInputFailed
        }
        return input
    }
    
    private func changeCaptureDevice(to device: AVCaptureDevice) async throws {
        guard let currentInput = activeVideoInput else { return }
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        captureSession.removeInput(currentInput)
        
        do {
            activeVideoInput = try addInput(for: device)
        } catch {
            captureSession.addInput(currentInput)
            throw error
        }
    }
}

// MARK: - Preview Support
protocol PreviewTarget: AnyObject {
    func setSession(_ session: AVCaptureSession)
}

protocol PreviewSource {
    func connect(to target: PreviewTarget)
}

extension CaptureService: PreviewSource {
    nonisolated func connect(to target: PreviewTarget) {
        target.setSession(captureSession)
    }
}