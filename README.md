# StarFlow Bench

Week-0 hardware characterization app for the **StarFlow** project: measures what the
**Insta360 Flow 2 Pro** gimbal can actually do under Apple DockKit motor control, plus
the iPhone's real capture cadence at 1-second exposures. The measurements from this app
set every controller constant in the StarFlow star-tracking design.

Built for iPhone 17 Pro / iOS 26.x (works on any iPhone 12+ with iOS 18+).

## What it measures

| # | Test | Answers |
|---|------|---------|
| 1 | **Capability probe** | Motor authority (does the gimbal accept commands?), roll-axis actuation (unverified anywhere publicly), `motionStates` feedback rate, accessory limits/identity. |
| 2 | **Relative-step ladder** | Smallest reliable `setOrientation` relative step (2° → 0.02°, alternating direction), realized-vs-commanded angle, settle time. **This is the single most important unknown — nobody on Earth has published it.** |
| 3 | **Slow-velocity ladder** | Whether `setAngularVelocity` executes at/near the sidereal rate (7.27e-5 rad/s) or has a stiction floor. |
| 4 | **Capture cadence** | Real shot-to-shot time for 1 s custom-exposure captures (Bayer RAW vs HEIC, responsive capture on/off) → the achievable integration duty cycle. |

Plus: live gimbal angle readout, DockKit `accessoryEvents` logging (press the gimbal
trigger/buttons while watching the event log), and a big red **STOP** button that zeroes
velocity (the gimbal otherwise executes its last velocity command forever).

All results are CSV files in the app's `Documents/BenchLogs/` — visible in the
**Files app** on the phone and in **iTunes File Sharing** on Windows.

## Building (no Mac needed)

Every push to `main` triggers GitHub Actions (`macos-26` runner) to build an
**unsigned IPA** artifact: Actions tab → latest run → `StarFlowBench-ipa`.

## Installing from Windows (one-time setup ~15 min)

1. Install **iTunes** and **iCloud** from Apple's website (NOT the Microsoft Store versions).
2. Install **AltServer for Windows** (altstore.io, v1.7.4+) — or Sideloadly as an alternative.
3. Connect the iPhone via USB, trust the computer, enable Wi-Fi sync in iTunes.
4. On the iPhone: Settings → Privacy & Security → **Developer Mode** → on → restart.
5. Download `StarFlowBench.ipa` from the Actions artifact (unzip the artifact zip).
6. AltServer tray icon → Install .ipa → select the file → sign in with your Apple ID.
7. First launch: Settings → General → VPN & Device Management → trust your developer profile.

Free-account limits: the app expires after **7 days** (just re-install), max 3 sideloaded
apps, 10 App IDs/week.

## Running the tests

1. Charge the gimbal, mount it on its tripod on a stable surface. **Free Tilt collar OFF.**
2. Mount the iPhone in the magnetic clamp (landscape), power on the gimbal.
3. Open StarFlow Bench, allow camera access. Wait for "docked".
4. If the gimbal ignores commands (probe reports no motion): single-press the trigger,
   or open the Insta360 app once, then come back.
5. Run tests 1 → 4 in order. Keep the phone plugged in for long runs.
6. Send the CSV files back for analysis (Files app share, or iTunes File Sharing).

## Safety

- The STOP button and app-backgrounding both command zero velocity.
- Keep the area around the gimbal clear — test 2 makes ~140 small moves.
- Close the Insta360 app during tests so it doesn't fight for the accessory.

---
Part of the StarFlow project — an iOS app that turns the Flow 2 Pro into a star tracker
for Milky Way astrophotography. 🤖 Scaffolded with [Claude Code](https://claude.com/claude-code)
