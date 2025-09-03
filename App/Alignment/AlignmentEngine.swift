import UIKit

// MARK: - Models

public struct AlignmentOptions {
    public var preferHomography: Bool = true
    public var enableVisionPrealign: Bool = true
    public var enableLocalRefine: Bool = false
    public var downscaleTargetMP: Double = 1.5 // ~1–2MP
    public var timeBudgetMS: Int = 80 // preview budget
    public var useAppleVision: Bool = true // prefer Vision when available
    public init() {}
    public init(preferHomography: Bool,
                enableVisionPrealign: Bool,
                enableLocalRefine: Bool,
                downscaleTargetMP: Double,
                timeBudgetMS: Int,
                useAppleVision: Bool) {
        self.preferHomography = preferHomography
        self.enableVisionPrealign = enableVisionPrealign
        self.enableLocalRefine = enableLocalRefine
        self.downscaleTargetMP = downscaleTargetMP
        self.timeBudgetMS = timeBudgetMS
        self.useAppleVision = useAppleVision
    }
}

public enum TransformModel {
    case identity
    case homography(matrix3x3: [Double], inliers: Int, inlierRatio: Double)
    case affine(matrix2x3: [Double], inliers: Int, inlierRatio: Double)
}

public struct AlignmentMetrics {
    public var runtimeMS: Int
    public var keypointsRef: Int
    public var keypointsMov: Int
    public var matches: Int
    public var inliers: Int
    public var inlierRatio: Double
}

public struct AlignmentResult {
    public var alignedImage: UIImage
    public var transformModel: TransformModel
    public var metrics: AlignmentMetrics
}

// MARK: - Engine

public final class AlignmentEngine {
    public static let shared = AlignmentEngine()
    private init() {}

    // Stub implementation: returns moving image unmodified and identity transform
    public func align(moving: UIImage, reference: UIImage, options: AlignmentOptions = .init()) -> AlignmentResult {
        if options.useAppleVision {
            if let res = VisionAligner.shared.align(moving: moving, reference: reference, targetMP: options.downscaleTargetMP, preferHomography: options.preferHomography) {
                return AlignmentResult(alignedImage: res.alignedImage, transformModel: res.transformModel, metrics: res.metrics)
            }
        }
        let metrics = AlignmentMetrics(runtimeMS: 0, keypointsRef: 0, keypointsMov: 0, matches: 0, inliers: 0, inlierRatio: 0)
        return AlignmentResult(alignedImage: moving, transformModel: .identity, metrics: metrics)
    }

    // Preview fast-path: render at preview size; default stub just aspect-fill scales
    public func previewAlignForOverlay(moving: UIImage, referencePreviewSize: CGSize, options: AlignmentOptions = .init()) -> UIImage {
        guard referencePreviewSize.width > 0, referencePreviewSize.height > 0 else { return moving }
        if options.useAppleVision {
            // Create a fake reference canvas at the preview size to drive warping
            let reference = blankImage(size: referencePreviewSize, scale: UIScreen.main.scale)
            if let res = VisionAligner.shared.align(moving: moving, reference: reference, targetMP: 1.0, preferHomography: options.preferHomography) {
                return res.alignedImage
            }
        }
        // Fallback: just aspect-fill to preview size
        let target = referencePreviewSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { ctx in
            let imgSize = moving.size
            let scale = max(target.width / imgSize.width, target.height / imgSize.height)
            let w = imgSize.width * scale
            let h = imgSize.height * scale
            let x = (target.width - w) / 2
            let y = (target.height - h) / 2
            moving.draw(in: CGRect(x: x, y: y, width: w, height: h))
        }
    }

    private func blankImage(size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Notes
// This file defines the public Swift API for image alignment. The actual implementation
// will be provided by an Objective-C++ wrapper over OpenCV (OCVAligner), and optionally
// Apple Vision for semantic pre-alignment. Until OpenCV is added to the project and the
// wrapper is wired into the build, these methods act as no-ops so the app compiles.
