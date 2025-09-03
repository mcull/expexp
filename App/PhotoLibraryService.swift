import Photos
import AVFoundation
import UIKit

actor PhotoLibraryService {
    
    var isPhotoLibraryReadWriteAccessGranted: Bool {
        get async {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            
            // Determine if the user previously authorized read/write access
            var isAuthorized = status == .authorized
            
            // If the system hasn't determined the user's authorization status,
            // explicitly prompt them for approval
            if status == .notDetermined {
                isAuthorized = await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
            }
            
            return isAuthorized
        }
    }
    
    func savePhoto(_ photo: AVCapturePhoto) async throws {
        // Confirm the user granted read/write access
        guard await isPhotoLibraryReadWriteAccessGranted else {
            throw PhotoLibraryError.accessDenied
        }
        
        // Create a data representation of the photo and its attachments
        guard let photoData = photo.fileDataRepresentation() else {
            throw PhotoLibraryError.invalidPhotoData
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                // Save the photo data
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: photoData, options: nil)
            } completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed)
                }
            }
        }
    }
    
    func saveImage(_ image: UIImage) async throws {
        // Confirm the user granted read/write access
        guard await isPhotoLibraryReadWriteAccessGranted else {
            throw PhotoLibraryError.accessDenied
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed)
                }
            }
        }
    }
}

enum PhotoLibraryError: Error, LocalizedError {
    case accessDenied
    case invalidPhotoData
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Photo library access denied. Please enable photo access in Settings."
        case .invalidPhotoData:
            return "Invalid photo data. Unable to save photo."
        case .saveFailed:
            return "Failed to save photo to library."
        }
    }
}