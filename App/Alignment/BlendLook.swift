import CoreImage

/// A selectable finishing "look" applied on top of the linear-average blend.
/// `.filmic` is the shipping default; `.neutral` and `.moody` exist for a future in-app picker.
enum BlendLook {
    case neutral
    case filmic
    case moody

    /// Applies this look's tone curve / color treatment to an sRGB CIImage and returns sRGB.
    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .neutral:
            return image
        case .filmic:
            return Self.sCurve(image, lift: 0.22, shoulder: 0.78)
        case .moody:
            let curved = Self.sCurve(image, lift: 0.18, shoulder: 0.82)
            let warm = curved.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5400, y: 0),   // nudge warmer
            ])
            return warm.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.12,
            ])
        }
    }

    /// Gentle film S-curve: lifts the quarter-tone and rolls the three-quarter-tone.
    private static func sCurve(_ img: CIImage, lift: CGFloat, shoulder: CGFloat) -> CIImage {
        img.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.0,  y: 0.0),
            "inputPoint1": CIVector(x: 0.25, y: lift),
            "inputPoint2": CIVector(x: 0.5,  y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: shoulder),
            "inputPoint4": CIVector(x: 1.0,  y: 1.0),
        ])
    }
}
