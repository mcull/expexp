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
        case .face:  return faceAlignment(moving: moving, reference: reference)
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

    // MARK: - Face (similarity: translate + rotate + uniform scale, pinned to the face)

    /// Acceptable face-scale ratio; outside this we assume a bad detection and fall back.
    static let faceScaleRange: ClosedRange<CGFloat> = 0.3...3.0

    private static func faceAlignment(moving: UIImage, reference: UIImage) -> FrameAlignment {
        guard let movCG = moving.cgImage, let refCG = reference.cgImage,
              let mEyes = eyeCenters(in: movCG), let rEyes = eyeCenters(in: refCG) else {
            return .unlocked
        }
        // Pixel-space geometry (true angle/scale); image dims for normalization.
        let mw = CGFloat(movCG.width), mh = CGFloat(movCG.height)
        let rw = CGFloat(refCG.width), rh = CGFloat(refCG.height)
        let mL = CGPoint(x: mEyes.left.x * mw, y: mEyes.left.y * mh)
        let mR = CGPoint(x: mEyes.right.x * mw, y: mEyes.right.y * mh)
        let rL = CGPoint(x: rEyes.left.x * rw, y: rEyes.left.y * rh)
        let rR = CGPoint(x: rEyes.right.x * rw, y: rEyes.right.y * rh)

        let mMidPx = CGPoint(x: (mL.x + mR.x) / 2, y: (mL.y + mR.y) / 2)
        let rMidPx = CGPoint(x: (rL.x + rR.x) / 2, y: (rL.y + rR.y) / 2)
        let mVec = CGVector(dx: mR.x - mL.x, dy: mR.y - mL.y)
        let rVec = CGVector(dx: rR.x - rL.x, dy: rR.y - rL.y)
        let mLen = max(hypot(mVec.dx, mVec.dy), 1e-6)
        let rLen = max(hypot(rVec.dx, rVec.dy), 1e-6)
        let scale = rLen / mLen
        guard faceScaleRange.contains(scale) else { return .unlocked }
        let rotation = atan2(rVec.dy, rVec.dx) - atan2(mVec.dy, mVec.dx)

        // Anchor = moving eye midpoint (normalized to moving image). Shift maps moving mid → ref
        // mid, normalized to the moving image dims (the frame the compositor draws).
        let anchor = CGPoint(x: mMidPx.x / mw, y: mMidPx.y / mh)
        let dx = (rMidPx.x / rw) - (mMidPx.x / mw)
        let dy = (rMidPx.y / rh) - (mMidPx.y / mh)
        return FrameAlignment(dx: dx, dy: dy, rotation: rotation, scale: scale, anchor: anchor, locked: true)
    }

    private struct EyeCenters { let left: CGPoint; let right: CGPoint }  // normalized, top-left origin

    /// Largest face's eye centers, normalized (0...1) in top-left coordinates.
    private static func eyeCenters(in cgImage: CGImage) -> EyeCenters? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do { try handler.perform([request]) } catch { return nil }
        guard let faces = request.results, !faces.isEmpty else { return nil }
        guard let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }
        guard let lm = face.landmarks,
              let left = lm.leftEye?.normalizedPoints, !left.isEmpty,
              let right = lm.rightEye?.normalizedPoints, !right.isEmpty else { return nil }
        let bbox = face.boundingBox
        func center(_ pts: [CGPoint]) -> CGPoint {
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let n = CGFloat(pts.count)
            // Landmark points are normalized within the bbox, bottom-left origin.
            let xBL = bbox.origin.x + (sum.x / n) * bbox.size.width
            let yBL = bbox.origin.y + (sum.y / n) * bbox.size.height
            return CGPoint(x: xBL, y: 1 - yBL)  // → top-left origin
        }
        return EyeCenters(left: center(left), right: center(right))
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
