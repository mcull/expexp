import UIKit
import Vision
import CoreImage

struct VisionAlignmentResult {
    let alignedImage: UIImage
    let transformModel: TransformModel
    let metrics: AlignmentMetrics
}

final class VisionAligner {
    static let shared = VisionAligner()
    private let ciContext = CIContext()
    private init() {}

    func align(moving: UIImage, reference: UIImage, targetMP: Double = 1.5, preferHomography: Bool = true, enableFacePrealign: Bool = true) -> VisionAlignmentResult? {
        let start = CFAbsoluteTimeGetCurrent()

        // Normalize orientations and compute shared downscale
        guard let refUp = movingToUp(reference), let movUp = movingToUp(moving) else { return nil }
        var (refScaled, movScaled, scale) = downscalePair(reference: refUp, moving: movUp, targetMP: targetMP)

        // Optional face-based similarity pre-align to improve portraits
        if enableFacePrealign, let pre = similarityPrealign(moving: movScaled, reference: refScaled) {
            movScaled = pre
        }

        // Try translational first for speed, then homography if requested
        if let obs = runTranslational(moving: movScaled, reference: refScaled), let aligned = applyAffine(observation: obs, moving: movUp, referenceSize: refUp.size, scale: scale) {
            let dt = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            let metrics = AlignmentMetrics(runtimeMS: dt, keypointsRef: 0, keypointsMov: 0, matches: 0, inliers: 0, inlierRatio: 0)
            return VisionAlignmentResult(alignedImage: aligned, transformModel: .affine(matrix2x3: transformArray(from: obs.alignmentTransform, scale: 1.0), inliers: 0, inlierRatio: 0), metrics: metrics)
        }

        guard preferHomography else { return nil }

        if let obs = runHomography(moving: movScaled, reference: refScaled), let aligned = applyHomography(observation: obs, moving: movUp, referenceSize: refUp.size, scale: scale) {
            let dt = Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
            let m = matrixArray(from: obs.warpTransform)
            let metrics = AlignmentMetrics(runtimeMS: dt, keypointsRef: 0, keypointsMov: 0, matches: 0, inliers: 0, inlierRatio: 0)
            return VisionAlignmentResult(alignedImage: aligned, transformModel: .homography(matrix3x3: m, inliers: 0, inlierRatio: 0), metrics: metrics)
        }

        return nil
    }

    // MARK: - Vision Requests

    private func runTranslational(moving: UIImage, reference: UIImage) -> VNImageTranslationAlignmentObservation? {
        guard let refCG = reference.cgImage, let movCG = moving.cgImage else { return nil }
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: movCG, options: [:])
        let handler = VNImageRequestHandler(cgImage: refCG, options: [:])
        try? handler.perform([req])
        return req.results?.first as? VNImageTranslationAlignmentObservation
    }

    private func runHomography(moving: UIImage, reference: UIImage) -> VNImageHomographicAlignmentObservation? {
        guard let refCG = reference.cgImage, let movCG = moving.cgImage else { return nil }
        let req = VNHomographicImageRegistrationRequest(targetedCGImage: movCG, options: [:])
        let handler = VNImageRequestHandler(cgImage: refCG, options: [:])
        try? handler.perform([req])
        return req.results?.first as? VNImageHomographicAlignmentObservation
    }

    // MARK: - Apply Transforms

    private func applyAffine(observation: VNImageTranslationAlignmentObservation, moving: UIImage, referenceSize: CGSize, scale: CGFloat) -> UIImage? {
        // VN transforms are in a bottom-left origin coordinate system. Convert the CGContext
        // to match Vision/CI coordinates by flipping Y, then apply the transform directly.
        let tScaled = observation.alignmentTransform
        let t = CGAffineTransform(a: tScaled.a, b: tScaled.b, c: tScaled.c, d: tScaled.d, tx: tScaled.tx * scale, ty: tScaled.ty * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = moving.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: referenceSize, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: referenceSize))
            // Flip to bottom-left coordinate space
            cg.translateBy(x: 0, y: referenceSize.height)
            cg.scaleBy(x: 1, y: -1)
            // Apply Vision transform and draw
            cg.concatenate(t)
            cg.draw(moving.cgImage!, in: CGRect(origin: .zero, size: moving.size))
        }
    }

    private func applyHomography(observation: VNImageHomographicAlignmentObservation, moving: UIImage, referenceSize: CGSize, scale: CGFloat) -> UIImage? {
        // Vision uses a bottom-left origin coordinate system. Core Image also uses a bottom-left origin.
        // Define corners in bottom-left space and pass transformed corners directly to CIPerspectiveTransform.
        let Hs = observation.warpTransform
        let H = scaleHomography(Hs, by: scale)
        let w = moving.size.width
        let h = moving.size.height
        // Bottom-left coords: TL:(0,h) TR:(w,h) BR:(w,0) BL:(0,0)
        let cornersBL = [CGPoint(x: 0, y: h), CGPoint(x: w, y: h), CGPoint(x: w, y: 0), CGPoint(x: 0, y: 0)]
        let dstBL = cornersBL.map { applyHomographyPoint(H, $0) }

        guard let ci = CIImage(image: moving) else { return nil }
        let filter = CIFilter(name: "CIPerspectiveTransform")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        // Input expects: topLeft, topRight, bottomRight, bottomLeft — which correspond to our BL-space ordering.
        filter.setValue(CIVector(cgPoint: dstBL[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: dstBL[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: dstBL[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: dstBL[3]), forKey: "inputBottomLeft")

        guard let out = filter.outputImage else { return nil }
        let rect = CGRect(origin: .zero, size: referenceSize)
        guard let cg = ciContext.createCGImage(out, from: rect) else { return nil }
        return UIImage(cgImage: cg, scale: moving.scale, orientation: .up)
    }

    // MARK: - Helpers

    private func movingToUp(_ image: UIImage) -> UIImage? {
        guard image.imageOrientation != .up else { return image }
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    private func downscalePair(reference: UIImage, moving: UIImage, targetMP: Double) -> (UIImage, UIImage, CGFloat) {
        func downscale(_ img: UIImage) -> (UIImage, CGFloat) {
            let mp = (img.size.width * img.size.height) / 1_000_000.0
            if mp <= targetMP { return (img, 1.0) }
            let scale = sqrt(CGFloat(mp / targetMP))
            let newSize = CGSize(width: img.size.width / scale, height: img.size.height / scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            img.draw(in: CGRect(origin: .zero, size: newSize))
            let reduced = UIGraphicsGetImageFromCurrentImageContext() ?? img
            UIGraphicsEndImageContext()
            return (reduced, scale)
        }
        let (refScaled, refScale) = downscale(reference)
        let (movScaled, movScale) = downscale(moving)
        // Use average scale if different to reduce mismatch; we will scale transforms by this factor.
        let scale = max(refScale, movScale)
        return (refScaled, movScaled, scale)
    }

    private func transformArray(from t: CGAffineTransform, scale: CGFloat) -> [Double] {
        return [Double(t.a), Double(t.b), 0.0, Double(t.c), Double(t.d), 0.0, Double(t.tx * scale), Double(t.ty * scale), 1.0]
    }

    private func matrixArray(from m: simd_float3x3) -> [Double] {
        return [Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z),
                Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z),
                Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)]
    }

    private func scaleHomography(_ m: simd_float3x3, by s: CGFloat) -> simd_float3x3 {
        // H_full = D * H_scaled * D^-1, with D = diag(s, s, 1)
        let D = simd_float3x3([SIMD3(Float(s), 0, 0), SIMD3(0, Float(s), 0), SIMD3(0, 0, 1)])
        let Dinv = simd_float3x3([SIMD3(1/Float(s), 0, 0), SIMD3(0, 1/Float(s), 0), SIMD3(0, 0, 1)])
        return D * m * Dinv
    }

    private func applyHomographyPoint(_ H: simd_float3x3, _ p: CGPoint) -> CGPoint {
        let v = SIMD3(Float(p.x), Float(p.y), 1)
        let r = H * v
        let w = max(r.z, 1e-6)
        return CGPoint(x: CGFloat(r.x / w), y: CGFloat(r.y / w))
    }

    // MARK: - Vision Face Similarity Prealign
    private func similarityPrealign(moving: UIImage, reference: UIImage) -> UIImage? {
        guard let movCG = moving.cgImage, let refCG = reference.cgImage else { return nil }
        // Detect faces
        let movObs = detectLargestFaceObservations(in: movCG)
        let refObs = detectLargestFaceObservations(in: refCG)
        guard let m = movObs, let r = refObs else { return nil }
        // Extract anchors (eyes preferred; fallback to face center+width)
        guard let mAnc = faceAnchorsTopLeft(from: m, imageSize: moving.size),
              let rAnc = faceAnchorsTopLeft(from: r, imageSize: reference.size) else { return nil }

        // Compute similarity mapping moving->reference around eye midpoints
        let mMid = CGPoint(x: (mAnc.leftEye.x + mAnc.rightEye.x)/2, y: (mAnc.leftEye.y + mAnc.rightEye.y)/2)
        let rMid = CGPoint(x: (rAnc.leftEye.x + rAnc.rightEye.x)/2, y: (rAnc.leftEye.y + rAnc.rightEye.y)/2)
        let mVec = CGVector(dx: mAnc.rightEye.x - mAnc.leftEye.x, dy: mAnc.rightEye.y - mAnc.leftEye.y)
        let rVec = CGVector(dx: rAnc.rightEye.x - rAnc.leftEye.x, dy: rAnc.rightEye.y - rAnc.leftEye.y)
        let mLen = max(hypot(mVec.dx, mVec.dy), 1e-6)
        let rLen = max(hypot(rVec.dx, rVec.dy), 1e-6)
        let scale = rLen / mLen
        let angle = atan2(rVec.dy, rVec.dx) - atan2(mVec.dy, mVec.dx)

        var t = CGAffineTransform.identity
        t = t.translatedBy(x: rMid.x, y: rMid.y)
        t = t.rotated(by: angle)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -mMid.x, y: -mMid.y)

        // Render moving into reference-sized canvas using similarity transform
        let format = UIGraphicsImageRendererFormat()
        format.scale = moving.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: reference.size, format: format)
        let prewarped = renderer.image { ctx in
            let cg = ctx.cgContext
            // Core Graphics is top-left; our anchors are top-left already
            cg.concatenate(t)
            moving.draw(in: CGRect(origin: .zero, size: moving.size))
        }
        return prewarped
    }

    private func detectLargestFaceObservations(in cgImage: CGImage) -> VNFaceObservation? {
        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([req])
        guard let faces = req.results as? [VNFaceObservation], !faces.isEmpty else { return nil }
        return faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
    }

    private struct FaceAnchors { let leftEye: CGPoint; let rightEye: CGPoint }

    private func faceAnchorsTopLeft(from obs: VNFaceObservation, imageSize: CGSize) -> FaceAnchors? {
        // Prefer eye landmarks; fallback to approximate using face box
        func mapPoint(_ p: CGPoint, in bbox: CGRect) -> CGPoint {
            // p is normalized in bbox (0..1). bbox is normalized in image, BL origin.
            let xBL = bbox.origin.x + p.x * bbox.size.width
            let yBL = bbox.origin.y + p.y * bbox.size.height
            // Convert to top-left image coords
            let x = xBL * imageSize.width
            let y = (1.0 - yBL) * imageSize.height
            return CGPoint(x: x, y: y)
        }
        if let lm = obs.landmarks,
           let left = lm.leftEye?.normalizedPoints,
           let right = lm.rightEye?.normalizedPoints,
           !left.isEmpty, !right.isEmpty {
            // Average landmark points for centers
            let l = left.reduce(CGPoint.zero) { CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y)) }
            let r = right.reduce(CGPoint.zero) { CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y)) }
            let lAvg = CGPoint(x: l.x / CGFloat(left.count), y: l.y / CGFloat(left.count))
            let rAvg = CGPoint(x: r.x / CGFloat(right.count), y: r.y / CGFloat(right.count))
            let bbox = obs.boundingBox
            return FaceAnchors(leftEye: mapPoint(lAvg, in: bbox), rightEye: mapPoint(rAvg, in: bbox))
        }
        // Fallback: approximate eyes horizontally across face center with width proportion
        let bbox = obs.boundingBox
        let centerBL = CGPoint(x: bbox.origin.x + bbox.size.width * 0.5, y: bbox.origin.y + bbox.size.height * 0.6)
        let width = bbox.size.width * imageSize.width
        let eyeOffset = width * 0.15
        let centerTL = CGPoint(x: centerBL.x * imageSize.width, y: (1.0 - centerBL.y) * imageSize.height)
        let left = CGPoint(x: centerTL.x - eyeOffset, y: centerTL.y)
        let right = CGPoint(x: centerTL.x + eyeOffset, y: centerTL.y)
        return FaceAnchors(leftEye: left, rightEye: right)
    }
}
