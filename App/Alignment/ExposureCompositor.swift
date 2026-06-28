import UIKit

/// The single lighten-blend compositor used by BOTH the live preview and the save path, so the
/// preview is a faithful (screen-cropped) preview of the saved result.
enum ExposureCompositor {
    /// Lighten-blends `frames` into `canvasSize`. Each frame is drawn aspect-fill, then transformed
    /// by its `FrameAlignment` (rotation/scale about the normalized anchor, then a normalized shift).
    /// `alignments[i]` corresponds to `frames[i]`; index 0 is the reference (identity).
    static func composite(frames: [UIImage],
                          alignments: [FrameAlignment],
                          canvasSize: CGSize,
                          scale: CGFloat,
                          exposureAlpha: CGFloat) -> UIImage? {
        guard !frames.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: canvasSize))
            for (i, frame) in frames.enumerated() {
                let a = i < alignments.count ? alignments[i] : .identity
                let base = aspectFillRect(imageSize: frame.size, canvasSize: canvasSize)
                let pivot = CGPoint(x: base.minX + a.anchor.x * base.width,
                                    y: base.minY + a.anchor.y * base.height)
                cg.saveGState()
                // Rotate/scale about the pivot, then apply the normalized shift.
                cg.translateBy(x: pivot.x + a.dx * base.width, y: pivot.y + a.dy * base.height)
                cg.rotate(by: a.rotation)
                cg.scaleBy(x: a.scale, y: a.scale)
                cg.translateBy(x: -pivot.x, y: -pivot.y)
                frame.draw(in: base, blendMode: .lighten, alpha: exposureAlpha)
                cg.restoreGState()
            }
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
