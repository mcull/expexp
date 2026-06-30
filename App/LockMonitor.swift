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
    /// Within this deviation, treat as fully locked (ring solid green). Generous for handheld.
    private let lockedThreshold: Double = 4 * .pi / 180   // 4°
    /// Deviation at which the ring reads empty (0). Between this and `lockedThreshold` it ramps.
    private let maxDeviation: Double = 16 * .pi / 180      // 16°
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
        let target: Double
        if dev <= lockedThreshold {
            target = 1                                  // solid green within the locked zone
        } else {
            target = max(0, 1 - (dev - lockedThreshold) / (maxDeviation - lockedThreshold))
        }
        lockProgress += (target - lockProgress) * smoothing
    }
}

private extension CMQuaternion {
    /// Rotation angle (radians) represented by this quaternion.
    var angle: Double { 2 * acos(max(-1, min(1, w))) }
}
