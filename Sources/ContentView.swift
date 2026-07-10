import SwiftUI

struct ContentView: View {
    @StateObject private var gimbal = GimbalService.shared
    @StateObject private var runner = BenchRunner.shared
    @StateObject private var camera = CameraService.shared

    @State private var stepReps = 10
    @State private var slowSeconds = 60.0
    @State private var cadenceFrames = 50
    @State private var cadenceRAW = true
    @State private var cadenceResponsive = true
    @State private var logFiles: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                gimbalSection
                testsSection
                cameraSection
                logsSection
            }
            .navigationTitle("StarFlow Bench")
            .task {
                UIApplication.shared.isIdleTimerDisabled = true
                gimbal.start()
                await camera.requestAndStart()
                logFiles = BenchLog.shared.listFiles()
            }
            .safeAreaInset(edge: .bottom) { stopBar }
        }
    }

    private var gimbalSection: some View {
        Section("Gimbal") {
            LabeledContent("Status", value: gimbal.isDocked ? "docked" : "not docked")
                .foregroundStyle(gimbal.isDocked ? .green : .orange)
            LabeledContent("System tracking",
                           value: gimbal.systemTrackingDisabled ? "disabled (ours)" : "ENABLED")
            if let m = gimbal.latestMotion {
                LabeledContent("Pitch / Yaw / Roll",
                               value: String(format: "%.3f° / %.3f° / %.3f°",
                                             m.pitch * 180 / .pi,
                                             m.yaw * 180 / .pi,
                                             m.roll * 180 / .pi))
                LabeledContent("Speed", value: String(format: "%.5f °/s",
                                                      m.speedMagnitude * 180 / .pi))
            }
            if let err = gimbal.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            DisclosureGroup("Limits & identity") {
                Text(gimbal.accessoryDescription).font(.caption.monospaced())
                Text(gimbal.limitsDescription).font(.caption.monospaced())
            }
        }
    }

    private var testsSection: some View {
        Section("Gimbal tests (run in order)") {
            if runner.running {
                VStack(alignment: .leading, spacing: 6) {
                    Text(runner.status).font(.callout)
                    ProgressView(value: runner.progress)
                }
                Button("Abort test", role: .destructive) { runner.abort() }
            } else {
                Text(runner.status).font(.caption).foregroundStyle(.secondary)

                Text("Do NOT touch the gimbal trigger while tests run — it toggles motor authority. Press it only after all tests, watching the event log.")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                Button("1 · Capability probe (~30 s)") {
                    Task { await runner.runProbe() }
                }
                .disabled(!gimbal.isDocked)

                Stepper("Seconds per rate: \(Int(slowSeconds))",
                        value: $slowSeconds, in: 20...600, step: 20)
                Button("2 · Velocity floor (0.05 → sidereal ↓)") {
                    Task { await runner.runSlowVelocity(secondsPerRate: slowSeconds) }
                }
                .disabled(!gimbal.isDocked)

                Stepper("Reps per step size: \(stepReps)", value: $stepReps, in: 3...50)
                Button("3 · Relative-step ladder (2° → 0.25°)") {
                    Task { await runner.runStepLadder(repsPerSize: stepReps) }
                }
                .disabled(!gimbal.isDocked)

                Button("4 · Velocity-impulse ladder (0.5° → 0.02°)") {
                    Task { await runner.runImpulseLadder(repsPerSize: stepReps) }
                }
                .disabled(!gimbal.isDocked)
            }
        }
    }

    private var cameraSection: some View {
        Section("Capture cadence test") {
            Text(camera.statusLine).font(.caption).foregroundStyle(.secondary)
            Stepper("Frames: \(cadenceFrames)", value: $cadenceFrames, in: 10...500, step: 10)
            Toggle("Bayer RAW", isOn: $cadenceRAW)
            Toggle("Responsive capture / ZSL", isOn: $cadenceResponsive)
            if camera.cadenceRunning {
                Button("Abort cadence", role: .destructive) { camera.abortCadence() }
            } else {
                Button("5 · Run cadence (1 s subs @ ISO 1600)") {
                    camera.runCadence(frames: cadenceFrames, iso: 1600,
                                      raw: cadenceRAW, responsive: cadenceResponsive)
                }
                .disabled(!camera.sessionRunning)
            }
        }
    }

    private var logsSection: some View {
        Section("Logs (also in Files app & iTunes File Sharing)") {
            Button("Refresh list") { logFiles = BenchLog.shared.listFiles() }
            ForEach(logFiles, id: \.self) { url in
                ShareLink(item: url) {
                    Text(url.lastPathComponent).font(.caption.monospaced())
                }
            }
            if !logFiles.isEmpty {
                Button("Delete all logs", role: .destructive) {
                    BenchLog.shared.deleteAll()
                    logFiles = []
                }
            }
            DisclosureGroup("Live event log") {
                ForEach(Array(gimbal.eventLines.suffix(60).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }

    private var stopBar: some View {
        Button {
            runner.abort()
            camera.abortCadence()
            Task { await gimbal.zeroVelocity() }
        } label: {
            Text("STOP — zero velocity")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }
}
