import Foundation
import Spatial

/// Runs the Week-0 measurement protocol against the docked gimbal and writes
/// CSV logs. All tests end by commanding zero velocity.
@MainActor
final class BenchRunner: ObservableObject {
    static let shared = BenchRunner()

    @Published var running = false
    @Published var status = "idle"
    @Published var progress: Double = 0
    @Published var suiteRunning = false

    private let gimbal = GimbalService.shared

    private init() {}

    // MARK: - Full automated suite (end-to-end, one tap / auto-armed)

    func runFullSuite() async {
        guard !suiteRunning, !running else { return }
        suiteRunning = true
        gimbal.log("FULL BENCH START")
        await runProbe()
        if suiteRunning { await runSlowVelocity(secondsPerRate: 20) }
        if suiteRunning { await runStepLadder(repsPerSize: 6) }
        if suiteRunning { await runImpulseLadder(repsPerSize: 6) }
        if suiteRunning {
            gimbal.log("cadence: starting (ZSL off, true 1 s)")
            let cam = CameraService.shared
            cam.runCadence(frames: 50, iso: 1600, raw: true, responsive: false)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while cam.cadenceRunning && suiteRunning {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            gimbal.log("cadence: \(cam.statusLine)")
        }
        gimbal.log(suiteRunning ? "FULL BENCH DONE" : "FULL BENCH ABORTED")
        suiteRunning = false
    }

    func abortSuite() {
        suiteRunning = false
        abort()
        CameraService.shared.abortCadence()
    }

    private func finish(_ message: String) async {
        await gimbal.zeroVelocity()
        status = message
        running = false
        progress = 0
        gimbal.log(message)
    }

    // MARK: - Test 1: capability probe

    func runProbe() async {
        guard !running else { return }
        running = true; status = "probe: starting"
        let csv = BenchLog.shared.newCSV(test: "probe", header: "key,value")
        defer { csv.close() }

        csv.row(["accessory", gimbal.accessoryDescription])
        csv.row(["limits", gimbal.limitsDescription])
        csv.row(["systemTrackingDisabled", "\(gimbal.systemTrackingDisabled)"])

        // Motor authority: tiny yaw velocity pulse, verify movement.
        status = "probe: motor authority (velocity pulse)"
        let before = await gimbal.averagePosition(seconds: 0.4)
        do {
            try await gimbal.setVelocity(yaw: 0.05)           // ~2.9 deg/s
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await gimbal.zeroVelocity()
            _ = await gimbal.waitSettled()
            let after = await gimbal.averagePosition(seconds: 0.4)
            let movedDeg = (after.1 - before.1) * 180 / .pi
            csv.row(["authority_velocity_moved_deg", String(format: "%.4f", movedDeg)])
            csv.row(["authority_ok", abs(movedDeg) > 0.5 ? "true" : "false"])
            gimbal.log(String(format: "probe: velocity pulse moved %.3f deg", movedDeg))
        } catch {
            csv.row(["authority_velocity_error", error.localizedDescription])
        }

        // Undo the pulse.
        try? await gimbal.relativeMove(yawDeg: -3.0, seconds: 1.0)
        _ = await gimbal.waitSettled()

        // Roll actuation probe: DockKit models pitch+yaw; roll support is unverified anywhere.
        status = "probe: roll axis"
        let rollBefore = await gimbal.averagePosition(seconds: 0.4)
        do {
            try await gimbal.relativeMove(rollDeg: 3.0, seconds: 1.0)
            _ = await gimbal.waitSettled()
            let rollAfter = await gimbal.averagePosition(seconds: 0.4)
            let rolledDeg = (rollAfter.2 - rollBefore.2) * 180 / .pi
            csv.row(["roll_commanded_deg", "3.0"])
            csv.row(["roll_realized_deg", String(format: "%.4f", rolledDeg)])
            gimbal.log(String(format: "probe: roll moved %.3f deg", rolledDeg))
            try? await gimbal.relativeMove(rollDeg: -3.0, seconds: 1.0)
            _ = await gimbal.waitSettled()
        } catch {
            csv.row(["roll_error", error.localizedDescription])
            gimbal.log("probe: roll rejected: \(error.localizedDescription)")
        }

        // motionStates cadence estimate.
        status = "probe: motionStates rate (2 s)"
        gimbal.startRecording()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let samples = gimbal.stopRecording()
        csv.row(["motionStates_samples_in_2s", "\(samples.count)"])
        csv.row(["motionStates_rate_hz", String(format: "%.1f", Double(samples.count) / 2.0)])

        await finish("probe: done → \(csv.url.lastPathComponent)")
    }

    // MARK: - Test 2: relative step ladder

    func runStepLadder(repsPerSize: Int) async {
        guard !running else { return }
        running = true
        // v2: run 1 explored the 2° -> 0.02° decade and found 2° works while 1°
        // no-ops — so v2 maps the 2° -> 0.25° region finely. Pitch keeps a short
        // ladder (its DockKit envelope is only −38°..+28°).
        let yawSizes: [Double] = [2.0, 1.5, 1.2, 1.0, 0.75, 0.5, 0.25]
        let pitchSizes: [Double] = [2.0, 1.0, 0.5]
        let csv = BenchLog.shared.newCSV(
            test: "stepladder",
            header: "axis,commanded_deg,rep,before_deg,after_deg,realized_deg,settle_s,error")
        defer { csv.close() }

        let total = Double((yawSizes.count + pitchSizes.count) * repsPerSize)
        var done = 0.0

        for (axis, sizes) in [("yaw", yawSizes), ("pitch", pitchSizes)] {
            for size in sizes {
                for rep in 0..<repsPerSize {
                    guard running else { await finish("step ladder: aborted"); return }
                    status = "steps: \(axis) \(size)° rep \(rep + 1)/\(repsPerSize)"
                    // Ride out transient undock/redock cycles instead of burning reps.
                    if !(await gimbal.waitForDock()) {
                        csv.row([axis, String(format: "%.3f", size), "\(rep)",
                                 "", "", "", "", "redock timeout"])
                        continue
                    }
                    // Alternate direction so we stay near the start pose.
                    let signed = (rep % 2 == 0) ? size : -size
                    let before = await gimbal.averagePosition(seconds: 0.5)
                    do {
                        if axis == "yaw" {
                            try await gimbal.relativeMove(yawDeg: signed, seconds: 0.6)
                        } else {
                            try await gimbal.relativeMove(pitchDeg: signed, seconds: 0.6)
                        }
                        let settle = await gimbal.waitSettled()
                        let after = await gimbal.averagePosition(seconds: 0.5)
                        let beforeDeg = (axis == "yaw" ? before.1 : before.0) * 180 / .pi
                        let afterDeg = (axis == "yaw" ? after.1 : after.0) * 180 / .pi
                        let settleStr = settle.map { String(format: "%.2f", $0) } ?? "timeout"
                        csv.row([axis, String(format: "%.3f", signed), "\(rep)",
                                 String(format: "%.5f", beforeDeg),
                                 String(format: "%.5f", afterDeg),
                                 String(format: "%.5f", afterDeg - beforeDeg),
                                 settleStr, ""])
                    } catch {
                        csv.row([axis, String(format: "%.3f", signed), "\(rep)",
                                 "", "", "", "", error.localizedDescription])
                        gimbal.log("step \(axis) \(signed)°: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: 700_000_000)
                    }
                    done += 1
                    progress = done / total
                }
            }
        }
        await finish("step ladder: done → \(csv.url.lastPathComponent)")
    }

    // MARK: - Test 2b: velocity-impulse ladder (fine-nudge candidate)

    /// Fine moves as timed velocity pulses (angle = rate x seconds). Run 1
    /// proved 0.05 rad/s velocity is accurate to <1%, while small
    /// setOrientation steps dead-banded — this measures the pulse alternative.
    func runImpulseLadder(repsPerSize: Int) async {
        guard !running else { return }
        running = true
        // (target degrees, rate rad/s) — durations stay >= 35 ms.
        let targets: [(Double, Double)] = [
            (0.5, 0.05), (0.25, 0.05), (0.1, 0.05), (0.05, 0.02), (0.02, 0.01),
        ]
        let csv = BenchLog.shared.newCSV(
            test: "impulseladder",
            header: "target_deg,rate_rad_s,pulse_s,rep,realized_deg,settle_s,error")
        defer { csv.close() }

        let total = Double(targets.count * repsPerSize)
        var done = 0.0

        for (targetDeg, rate) in targets {
            let pulse = (targetDeg * .pi / 180) / rate
            for rep in 0..<repsPerSize {
                guard running else { await finish("impulse ladder: aborted"); return }
                status = String(format: "impulse: %.2f° (%.0f ms) rep %d/%d",
                                targetDeg, pulse * 1000, rep + 1, repsPerSize)
                if !(await gimbal.waitForDock()) {
                    csv.row([String(format: "%.3f", targetDeg), "\(rate)",
                             String(format: "%.3f", pulse), "\(rep)", "", "", "redock timeout"])
                    continue
                }
                let sign: Double = (rep % 2 == 0) ? 1 : -1
                let before = await gimbal.averagePosition(seconds: 0.5)
                do {
                    try await gimbal.velocityPulse(yawRadPerSec: rate * sign, seconds: pulse)
                    let settle = await gimbal.waitSettled()
                    let after = await gimbal.averagePosition(seconds: 0.5)
                    let realized = (after.1 - before.1) * 180 / .pi
                    csv.row([String(format: "%.3f", targetDeg * sign), "\(rate)",
                             String(format: "%.3f", pulse), "\(rep)",
                             String(format: "%.5f", realized),
                             settle.map { String(format: "%.2f", $0) } ?? "timeout", ""])
                } catch {
                    csv.row([String(format: "%.3f", targetDeg * sign), "\(rate)",
                             String(format: "%.3f", pulse), "\(rep)", "", "",
                             error.localizedDescription])
                }
                done += 1
                progress = done / total
            }
        }
        await finish("impulse ladder: done → \(csv.url.lastPathComponent)")
    }

    // MARK: - Test 3: slow-velocity ladder (sidereal probe)

    func runSlowVelocity(secondsPerRate: Double) async {
        guard !running else { return }
        running = true
        // v2: DESCEND from the proven-working 0.05 rad/s to find the floor.
        // Run 1's all-rejected result was ambiguous (possible authority loss);
        // starting from a known-good rate disambiguates: if 0.05 works and
        // 7.27e-5 errors, the rejection is a real velocity floor.
        let rates: [Double] = [0.05, 0.02, 0.01, 0.005, 0.002, 7.27e-4, 3.64e-4, 7.27e-5]
        let csv = BenchLog.shared.newCSV(
            test: "slowvelocity",
            header: "commanded_rad_s,elapsed_s,yaw_deg_moved,achieved_rad_s,samples")
        defer { csv.close() }
        let trace = BenchLog.shared.newCSV(
            test: "slowvelocity_trace",
            header: "commanded_rad_s,t_wall,yaw_rad,vyaw_rad_s")
        defer { trace.close() }

        for (i, rate) in rates.enumerated() {
            guard running else { await finish("slow velocity: aborted"); return }
            status = String(format: "velocity: %.2e rad/s for %.0f s", rate, secondsPerRate)
            if !(await gimbal.waitForDock()) {
                csv.row([String(format: "%.3e", rate), "0", "", "", "redock timeout"])
                continue
            }
            let before = await gimbal.averagePosition(seconds: 0.5)
            gimbal.startRecording()
            do {
                try await gimbal.setVelocity(yaw: rate)
            } catch {
                csv.row([String(format: "%.3e", rate), "0", "", "", "error: \(error.localizedDescription)"])
                continue
            }
            let t0 = Date()
            while Date().timeIntervalSince(t0) < secondsPerRate && running {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await gimbal.zeroVelocity()
            let samples = gimbal.stopRecording()
            _ = await gimbal.waitSettled()
            let after = await gimbal.averagePosition(seconds: 0.5)
            let elapsed = Date().timeIntervalSince(t0)
            let movedRad = after.1 - before.1
            csv.row([String(format: "%.3e", rate),
                     String(format: "%.1f", elapsed),
                     String(format: "%.5f", movedRad * 180 / .pi),
                     String(format: "%.3e", movedRad / elapsed),
                     "\(samples.count)"])
            for s in samples where samples.count < 5000 {
                trace.row([String(format: "%.3e", rate),
                           String(format: "%.3f", s.wall),
                           String(format: "%.6f", s.yaw),
                           String(format: "%.6e", s.vYaw)])
            }
            gimbal.log(String(format: "rate %.2e: moved %.4f deg in %.0f s",
                              rate, movedRad * 180 / .pi, elapsed))
            progress = Double(i + 1) / Double(rates.count)
        }
        await finish("slow velocity: done → \(csv.url.lastPathComponent)")
    }

    func abort() {
        running = false
        Task { await gimbal.zeroVelocity() }
    }
}
