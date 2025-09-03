import Photos
import UIKit

enum SaveManager {
    static func save(_ image: UIImage, completion: @escaping (Bool, Error?) -> Void) {
        let perform = {
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            }) { ok, err in
                DispatchQueue.main.async { completion(ok, err) }
            }
        }
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: perform()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in DispatchQueue.main.async { perform() } }
        default: completion(false, NSError(domain: "Save", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photos permission denied"]))
        }
    }
}

