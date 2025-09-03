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

    func align(moving: UIImage, reference: UIImage, targetMP: Double = 1.5, preferHomography: Bool = true) -> VisionAlignmentResult? {
        let start = CFAbsoluteTimeGetCurrent()

        // Normalize orientations and compute shared downscale
        guard let refUp = movingToUp(reference), let movUp = movingToUp(moving) else { return nil }
        let (refScaled, movScaled, scale) = downscalePair(reference: refUp, moving: movUp, targetMP: targetMP)

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
        // Convert 3x3 to map the four corners of the moving image to destination points, scaled to full-res
        let Hs = observation.warpTransform
        let H = scaleHomography(Hs, by: scale)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: moving.size.width, y: 0), CGPoint(x: moving.size.width, y: moving.size.height), CGPoint(x: 0, y: moving.size.height)]
        let dst = corners.map { applyHomographyPoint(H, $0) }

        guard let ci = CIImage(image: moving) else { return nil }
        let filter = CIFilter(name: "CIPerspectiveTransform")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        // Core Image expects dest corners in order: topLeft, topRight, bottomRight, bottomLeft
        filter.setValue(CIVector(cgPoint: dst[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: dst[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: dst[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: dst[3]), forKey: "inputBottomLeft")

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
}
