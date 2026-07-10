import Foundation
import DockKit
import Spatial

enum BenchError: LocalizedError {
    case notDocked
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .notDocked: return "No gimbal docked"
        case .timeout(let what): return "Timed out waiting for \(what)"
        }
    }
}

struct MotionSample: Sendable {
    let t: TimeInterval          // unix epoch from the accessory
    let wall: TimeInterval       // Date().timeIntervalSince1970 at receipt
    let pitch: Double, yaw: Double, roll: Double        // rad
    let vPitch: Double, vYaw: Double, vRoll: Double     // rad/s

    var speedMagnitude: Double {
        max(abs(vPitch), max(abs(vYaw), abs(vRoll)))
    }
}

/// Owns the DockKit connection, the motion/event feeds, and the safety rules.
/// SAFETY INVARIANT: the accessory executes its last commanded velocity forever,
/// so every stop path must command zero velocity.
@MainActor
final class GimbalService: ObservableObject {
    static let shared = GimbalService()

    @Published var isDocked = false
    @Published var accessoryDescription = "waiting for gimbal…"
    @Published var limitsDescription = "—"
    @Published var trackingButtonEnabled = false
    @Published var systemTrackingDisabled = false
    @Published var latestMotion: MotionSample?
    @Published var eventLines: [String] = []
    @Published var lastError: String?

    private(set) var accessory: DockAccessory?
    private var connectionTask: Task<Void, Never>?
    private var motionTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    private var recording = false
    private(set) var recorded: [MotionSample] = []

    private init() {}

    func start() {
        guard connectionTask == nil else { return }
        connectionTask = Task {
            do {
                for await change in try DockAccessoryManager.shared.accessoryStateChanges {
                    self.trackingButtonEnabled = change.trackingButtonEnabled
                    if change.state == .docked, let acc = change.accessory {
                        self.attach(acc)
                    } else if change.state == .undocked {
                        await self.detach()
                    }
                    self.log("state: \(change.state) trackingButtonEnabled: \(change.trackingButtonEnabled)")
                }
            } catch {
                self.lastError = "accessoryStateChanges: \(error.localizedDescription)"
            }
        }
    }

    /// Must be re-asserted on every foregrounding — the flag does not persist.
    func disableSystemTracking() {
        Task {
            do {
                try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
                systemTrackingDisabled = true
                log("system tracking disabled")
            } catch {
                systemTrackingDisabled = false
                lastError = "setSystemTrackingEnabled: \(error.localizedDescription)"
            }
        }
    }

    private func attach(_ acc: DockAccessory) {
        accessory = acc
        isDocked = true
        accessoryDescription = String(describing: acc)
        limitsDescription = String(describing: acc.limits)
        disableSystemTracking()
        startMotionFeed(acc)
        startEventFeed(acc)
        log("docked: \(accessoryDescription)")
    }

    private func detach() async {
        await zeroVelocity()
        motionTask?.cancel(); motionTask = nil
        eventsTask?.cancel(); eventsTask = nil
        accessory = nil
        isDocked = false
        accessoryDescription = "undocked"
        log("undocked")
    }

    private func startMotionFeed(_ acc: DockAccessory) {
        motionTask?.cancel()
        motionTask = Task {
            do {
                for try await state in acc.motionStates {
                    let sample = MotionSample(
                        t: state.timestamp,
                        wall: Date().timeIntervalSince1970,
                        pitch: state.angularPositions.x,
                        yaw: state.angularPositions.y,
                        roll: state.angularPositions.z,
                        vPitch: state.angularVelocities.x,
                        vYaw: state.angularVelocities.y,
                        vRoll: state.angularVelocities.z)
                    self.latestMotion = sample
                    if self.recording { self.recorded.append(sample) }
                }
            } catch {
                self.log("motionStates ended: \(error.localizedDescription)")
            }
        }
    }

    private func startEventFeed(_ acc: DockAccessory) {
        eventsTask?.cancel()
        eventsTask = Task {
            do {
                for try await event in acc.accessoryEvents {
                    self.log("EVENT \(String(describing: event))")
                }
            } catch {
                self.log("accessoryEvents ended: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Motion commands

    func zeroVelocity() async {
        guard let acc = accessory else { return }
        try? await acc.setAngularVelocity(Vector3D(x: 0, y: 0, z: 0))
    }

    func setVelocity(pitch: Double = 0, yaw: Double = 0, roll: Double = 0) async throws {
        guard let acc = accessory else { throw BenchError.notDocked }
        try await acc.setAngularVelocity(Vector3D(x: pitch, y: yaw, z: roll))
    }

    /// Relative orientation move in degrees. Returns immediately after issuing;
    /// callers watch motionStates for settling.
    func relativeMove(pitchDeg: Double = 0, yawDeg: Double = 0, rollDeg: Double = 0,
                      seconds: Double = 1.0) async throws {
        guard let acc = accessory else { throw BenchError.notDocked }
        let target = Vector3D(x: pitchDeg * .pi / 180,
                              y: yawDeg * .pi / 180,
                              z: rollDeg * .pi / 180)
        _ = try await acc.setOrientation(target, duration: .seconds(seconds), relative: true)
    }

    // MARK: - Measurement helpers

    func startRecording() { recorded.removeAll(); recording = true }

    func stopRecording() -> [MotionSample] {
        recording = false
        return recorded
    }

    /// Waits until all axis speeds stay below `threshold` rad/s for `stableFor`
    /// seconds. Returns the time in seconds it took to settle, or nil on timeout.
    func waitSettled(threshold: Double = 2e-4, stableFor: Double = 0.3,
                     timeout: Double = 6.0) async -> Double? {
        let start = Date()
        var stableSince: Date?
        while Date().timeIntervalSince(start) < timeout {
            if let m = latestMotion, m.speedMagnitude < threshold {
                if stableSince == nil { stableSince = Date() }
                if Date().timeIntervalSince(stableSince!) >= stableFor {
                    return Date().timeIntervalSince(start) - stableFor
                }
            } else {
                stableSince = nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// Averages the reported axis positions over `seconds`. Returns (pitch, yaw, roll) in rad.
    func averagePosition(seconds: Double = 0.5) async -> (Double, Double, Double) {
        var samples: [(Double, Double, Double)] = []
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if let m = latestMotion { samples.append((m.pitch, m.yaw, m.roll)) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !samples.isEmpty else { return (0, 0, 0) }
        let n = Double(samples.count)
        return (samples.map(\.0).reduce(0, +) / n,
                samples.map(\.1).reduce(0, +) / n,
                samples.map(\.2).reduce(0, +) / n)
    }

    func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        eventLines.append("\(stamp)  \(line)")
        if eventLines.count > 400 { eventLines.removeFirst(eventLines.count - 400) }
    }
}
