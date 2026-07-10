import UIKit
import CoreImage

/// The single compositor used by BOTH the live preview and the save path (WYSIWYG).
/// Produces an equal-weight, order-independent, coverage-weighted average of the aligned frames
/// in LINEAR light, finished with a `BlendLook` tone curve.
enum ExposureCompositor {
    /// How much a growing stack dims each layer. A strict average divides by the frame count,
    /// so every one of `n` layers contributes only `1/n` — by the 4th or 5th shot each layer is
    /// nearly invisible. After averaging we lift the result by `count^(1 - layerPersistence)`,
    /// which keeps later layers readable while preserving the "averages down" feel.
    ///   1.0 → strict average (flat brightness, original behavior)
    ///   0.7 → gentle lift (gain ≈ 1.3× at 3 shots, 1.6× at 5) — current default
    ///   0.5 → stronger, more additive (gain ≈ 1.7× at 3, 2.2× at 5; may bloom highlights)
    /// Nudge this one number to taste.
    static let layerPersistence: CGFloat = 0.5

    /// Linear-light working space for the averaging stage.
    private static let linearContext: CIContext = {
        if let linear = CGColorSpace(name: CGColorSpace.linearSRGB) {
            return CIContext(options: [.workingColorSpace: linear])
        }
        return CIContext()
    }()
    /// sRGB working space for the tone-curve stage (so curves act on sRGB values).
    private static let toneContext: CIContext = {
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            return CIContext(options: [.workingColorSpace: srgb])
        }
        return CIContext()
    }()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    static func composite(frames: [UIImage],
                          alignments: [FrameAlignment],
                          canvasSize: CGSize,
                          scale: CGFloat,
                          look: BlendLook) -> UIImage? {
        guard !frames.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        // 1. Render each aligned frame into its own canvas-sized image (proven UIKit geometry).
        var positioned: [CIImage] = []
        for (i, frame) in frames.enumerated() {
            let a = i < alignments.count ? alignments[i] : .identity
            guard let img = renderPositioned(frame: frame, alignment: a, canvasSize: canvasSize, scale: scale),
                  let ci = CIImage(image: img) else { continue }
            positioned.append(ci)
        }
        guard !positioned.isEmpty else { return nil }

        // 2. Coverage-weighted equal-weight average in LINEAR light: composite the i-th frame
        //    (1-indexed) at opacity 1/i with source-over → running mean; transparent gaps don't
        //    contribute, so each pixel averages only the frames that cover it.
        var acc: CIImage?
        for (idx, ci) in positioned.enumerated() {
            let opacity = CGFloat(1.0) / CGFloat(idx + 1)
            let faded = ci.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
            if let a = acc {
                acc = faded.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: a])
            } else {
                acc = faded
            }
        }
        guard let averaged = acc else { return nil }

        // 2b. Lift the average so a tall stack's faint layers stay readable (see `layerPersistence`).
        //     Scales RGB in linear light; leaves alpha (coverage) untouched.
        let gain = pow(CGFloat(max(positioned.count, 1)), 1 - layerPersistence)
        let lifted: CIImage
        if abs(gain - 1) < 0.001 {
            lifted = averaged
        } else {
            lifted = averaged.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        }

        // 3. Render the linear average to sRGB pixels.
        let pxRect = CGRect(x: 0, y: 0, width: canvasSize.width * scale, height: canvasSize.height * scale)
        let renderSpace = sRGB ?? CGColorSpaceCreateDeviceRGB()
        guard let avgCG = linearContext.createCGImage(lifted, from: pxRect, format: .RGBA8, colorSpace: renderSpace) else {
            return nil
        }

        // 4. Apply the look's tone curve (acts on sRGB values), render to the final image.
        let toned = look.apply(to: CIImage(cgImage: avgCG))
        guard let finalCG = toneContext.createCGImage(toned, from: toned.extent, format: .RGBA8, colorSpace: renderSpace) else {
            return UIImage(cgImage: avgCG, scale: scale, orientation: .up)
        }
        return UIImage(cgImage: finalCG, scale: scale, orientation: .up)
    }

    /// Draws one frame into a transparent canvas-sized image, applying its alignment transform
    /// (rotate/scale about the normalized anchor, then a normalized shift) over an aspect-fill base.
    private static func renderPositioned(frame: UIImage,
                                         alignment a: FrameAlignment,
                                         canvasSize: CGSize,
                                         scale: CGFloat) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: canvasSize))
            let base = aspectFillRect(imageSize: frame.size, canvasSize: canvasSize)
            let pivot = CGPoint(x: base.minX + a.anchor.x * base.width,
                                y: base.minY + a.anchor.y * base.height)
            cg.saveGState()
            cg.translateBy(x: pivot.x + a.dx * base.width, y: pivot.y + a.dy * base.height)
            cg.rotate(by: a.rotation)
            cg.scaleBy(x: a.scale, y: a.scale)
            cg.translateBy(x: -pivot.x, y: -pivot.y)
            frame.draw(in: base)   // opaque draw (no blend); alpha = 1 where covered, 0 in gaps
            cg.restoreGState()
        }
    }

    private static func aspectFillRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let s = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (canvasSize.width - w) / 2, y: (canvasSize.height - h) / 2, width: w, height: h)
    }
}
