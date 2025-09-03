import UIKit

// MARK: - Models

public struct AlignmentOptions {
    public var preferHomography: Bool = true
    public var enableVisionPrealign: Bool = true
    public var enableLocalRefine: Bool = false
    public var downscaleTargetMP: Double = 1.5 // ~1–2MP
    public var timeBudgetMS: Int = 80 // preview budget
    public init() {}
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
        let metrics = AlignmentMetrics(runtimeMS: 0, keypointsRef: 0, keypointsMov: 0, matches: 0, inliers: 0, inlierRatio: 0)
        return AlignmentResult(alignedImage: moving, transformModel: .identity, metrics: metrics)
    }

    // Preview fast-path: render at preview size; default stub just aspect-fill scales
    public func previewAlignForOverlay(moving: UIImage, referencePreviewSize: CGSize, options: AlignmentOptions = .init()) -> UIImage {
        guard referencePreviewSize.width > 0, referencePreviewSize.height > 0 else { return moving }
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
}

// MARK: - Notes
// This file defines the public Swift API for image alignment. The actual implementation
// will be provided by an Objective-C++ wrapper over OpenCV (OCVAligner), and optionally
// Apple Vision for semantic pre-alignment. Until OpenCV is added to the project and the
// wrapper is wired into the build, these methods act as no-ops so the app compiles.

