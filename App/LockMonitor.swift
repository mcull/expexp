import Foundation
import CoreMotion

/// Turns device attitude (gyro) into a flight-sim style level reading relative to a reference
/// orientation captured at the first exposure:
///  - `levelOffset`: normalized bubble position (x = yaw, y = pitch), ~-1…1, .zero when matched.
///  - `roll`: relative roll (radians) for banking the reticle.
///  - `isCentered`: true when the device is back within a small tolerance of the reference.
/// Cheap and immune to moving subjects (it measures only the device's own rotation). It does NOT
/// see sideways translation — the ghost overlay covers that.
@MainActor
final class LockMonitor: ObservableObject {
    @Published private(set) var levelOffset: CGSize = .zero
    @Published private(set) var roll: Double = 0
    @Published private(set) var isCentered: Bool = false

    private let motion = CMMotionManager()
    private var reference: CMAttitude?
    /// Deviation (radians) that pushes the bubble to the edge of the reticle.
    private let maxDeviation: Double = 12 * .pi / 180   // 12°
    /// Within this total deviation, treat as centered/matched.
    private let centeredThreshold: Double = 2.5 * .pi / 180   // 2.5°
    private let smoothing: Double = 0.25

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let attitude = data?.attitude else { return }
            self.update(with: attitude)
        }
    }

    func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        clearReference()
    }

    /// Capture the current orientation as the reference (call on the first exposure).
    func setReference() {
        reference = motion.deviceMotion?.attitude.copy() as? CMAttitude
        levelOffset = .zero
        roll = 0
        isCentered = reference != nil
    }

    /// Drop the reference so the reticle reads neutral until the next stack starts.
    func clearReference() {
        reference = nil
        levelOffset = .zero
        roll = 0
        isCentered = false
    }

    private func update(with current: CMAttitude) {
        guard let reference else { return }
        let rel = current.copy() as! CMAttitude
        rel.multiply(byInverseOf: reference)

        // Yaw → horizontal, pitch → vertical (signs tuned for on-screen feel).
        let nx = clamp(rel.yaw / maxDeviation)
        let ny = clamp(rel.pitch / maxDeviation)
        let sx = levelOffset.width + (nx - levelOffset.width) * smoothing
        let sy = levelOffset.height + (ny - levelOffset.height) * smoothing
        levelOffset = CGSize(width: sx, height: sy)
        roll += (rel.roll - roll) * smoothing

        let dev = hypot(rel.yaw, rel.pitch)
        isCentered = dev <= centeredThreshold && abs(rel.roll) <= centeredThreshold
    }

    private func clamp(_ v: Double) -> Double { max(-1, min(1, v)) }
}
