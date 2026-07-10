import SwiftUI

@main
struct StarFlowBenchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // SAFETY: never leave the gimbal executing a stale velocity.
            if phase != .active {
                Task { await GimbalService.shared.zeroVelocity() }
            }
            if phase == .active {
                // System-tracking flag does not persist across foregrounding.
                GimbalService.shared.disableSystemTracking()
            }
        }
    }
}
