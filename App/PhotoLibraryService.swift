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
        
        print("💾 DEBUG: Saving image with size: \(image.size), orientation: \(image.imageOrientation.rawValue)")
        
        // Convert to data with explicit orientation to avoid Photos framework auto-rotation
        guard let imageData = image.jpegData(compressionQuality: 0.9) else {
            throw PhotoLibraryError.invalidPhotoData
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                // Use data-based creation to maintain exact orientation
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: imageData, options: nil)
                print("💾 DEBUG: Creating asset from JPEG data to preserve orientation")
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

    // Save and return the localIdentifier of the created asset for later reference.
    func saveImageReturningLocalIdentifier(_ image: UIImage) async throws -> String {
        // Confirm the user granted read/write access
        guard await isPhotoLibraryReadWriteAccessGranted else {
            throw PhotoLibraryError.accessDenied
        }

        print("💾 DEBUG: Saving image (with identifier) size: \(image.size), orientation: \(image.imageOrientation.rawValue)")

        guard let imageData = image.jpegData(compressionQuality: 0.9) else {
            throw PhotoLibraryError.invalidPhotoData
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var placeholderId: String?
            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                creationRequest.addResource(with: .photo, data: imageData, options: options)
                placeholderId = creationRequest.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if success, let id = placeholderId {
                    continuation.resume(returning: id)
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
