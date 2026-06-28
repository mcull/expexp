import UIKit
import Vision

/// Which feature the alignment should "freeze."
enum AlignmentAnchor {
    case scene   // freeze the static structure (back camera / cityscape)
    case face    // freeze the user's face (front camera / selfie swirl) — Phase B
}

/// A resolution-independent alignment of one frame relative to the first (reference) frame.
/// Translation is stored as a fraction of the frame's width/height so it maps correctly to any
/// canvas size. Rotation (radians) and uniform `scale` default to identity (scene/translational);
/// `anchor` is the normalized (0...1, top-left) point that rotation/scale pivot about.
struct FrameAlignment {
    var dx: CGFloat
    var dy: CGFloat
    var rotation: CGFloat
    var scale: CGFloat
    var anchor: CGPoint
    var locked: Bool   // true if alignment succeeded; false if it fell back to no-op

    /// The reference frame (frame 0): no movement, considered locked.
    static let identity = FrameAlignment(dx: 0, dy: 0, rotation: 0, scale: 1,
                                         anchor: CGPoint(x: 0.5, y: 0.5), locked: true)
    /// A frame whose alignment could not be trusted: draw it unshifted, flag it unlocked.
    static let unlocked = FrameAlignment(dx: 0, dy: 0, rotation: 0, scale: 1,
                                         anchor: CGPoint(x: 0.5, y: 0.5), locked: false)
}

enum AlignmentService {
    /// Max plausible handheld shift as a fraction of the frame. Larger ⇒ assume mis-lock.
    static let maxShiftFraction: CGFloat = 0.30
    /// Long-side pixel size used for registration (downscaled for speed; fractions are scale-free).
    static let registrationMaxDimension: CGFloat = 1200

    static func alignment(moving: UIImage, reference: UIImage, anchor: AlignmentAnchor) -> FrameAlignment {
        switch anchor {
        case .scene: return sceneAlignment(moving: moving, reference: reference)
        case .face:  return .unlocked   // implemented in Phase B (Task B1)
        }
    }

    // MARK: - Scene (translational)

    private static func sceneAlignment(moving: UIImage, reference: UIImage) -> FrameAlignment {
        guard let refCG = downscaled(reference, maxDimension: registrationMaxDimension),
              let movCG = downscaled(moving, maxDimension: registrationMaxDimension) else {
            return .unlocked
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: movCG)
        let handler = VNImageRequestHandler(cgImage: refCG)
        do { try handler.perform([request]) } catch { return .unlocked }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return .unlocked
        }
        // Vision gives a pixel translation; the proven preview convention is (tx, -ty) in
        // top-left coords. Normalize by the registration image's pixel dimensions.
        let w = CGFloat(refCG.width), h = CGFloat(refCG.height)
        guard w > 0, h > 0 else { return .unlocked }
        let dx = obs.alignmentTransform.tx / w
        let dy = -obs.alignmentTransform.ty / h
        if abs(dx) > maxShiftFraction || abs(dy) > maxShiftFraction { return .unlocked }
        return FrameAlignment(dx: dx, dy: dy, rotation: 0, scale: 1,
                              anchor: CGPoint(x: 0.5, y: 0.5), locked: true)
    }

    // MARK: - Helpers

    /// Downscales to `maxDimension` on the long side via UIKit drawing (top-left, no flip), so
    /// reference and moving are reduced identically and the translation convention is preserved.
    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> CGImage? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        guard longest > maxDimension else { return image.cgImage }
        let s = maxDimension / longest
        let newSize = CGSize(width: size.width * s, height: size.height * s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let reduced = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return reduced.cgImage
    }
}
