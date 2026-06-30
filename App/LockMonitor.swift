import Foundation
import CoreMotion

/// Turns device attitude (gyro) into a smoothed 0…1 "lock" value: 1 when the device is held in
/// the same orientation as when `setReference()` was called, falling off as it rotates away.
/// Cheap and immune to moving subjects (it measures only the device's own motion).
@MainActor
final class LockMonitor: ObservableObject {
    /// Smoothed lock value, 0 (off-target) … 1 (locked).
    @Published private(set) var lockProgress: Double = 0

    private let motion = CMMotionManager()
    private var reference: CMAttitude?
    /// Angular deviation (radians) at which lock reads 0. ~8° feels right for handheld jitter.
    private let maxDeviation: Double = 8 * .pi / 180
    /// EMA smoothing factor (0..1); lower = smoother.
    private let smoothing: Double = 0.2

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
        reference = nil
        lockProgress = 0
    }

    /// Capture the current orientation as the "aligned" reference (call on the first exposure).
    func setReference() {
        reference = motion.deviceMotion?.attitude.copy() as? CMAttitude
        lockProgress = reference == nil ? 0 : 1
    }

    /// Drop the reference so the ring reads neutral until the next stack starts.
    func clearReference() {
        reference = nil
        lockProgress = 0
    }

    private func update(with current: CMAttitude) {
        guard let reference else { return }
        let rel = current.copy() as! CMAttitude
        rel.multiply(byInverseOf: reference)
        let dev = abs(rel.quaternion.angle)
        let target = max(0, 1 - dev / maxDeviation)
        lockProgress += (target - lockProgress) * smoothing
    }
}

private extension CMQuaternion {
    /// Rotation angle (radians) represented by this quaternion.
    var angle: Double { 2 * acos(max(-1, min(1, w))) }
}
