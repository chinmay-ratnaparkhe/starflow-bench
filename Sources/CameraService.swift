import Foundation
import AVFoundation
import ImageIO
import UIKit

/// Minimal camera stack: keeps an AVCaptureSession alive (DockKit expects a
/// camera-enabled app) and runs the capture-cadence test: back-to-back 1 s
/// custom-exposure captures, logging shot-to-shot timing.
@MainActor
final class CameraService: NSObject, ObservableObject {
    static let shared = CameraService()

    @Published var authorized = false
    @Published var sessionRunning = false
    @Published var statusLine = "camera idle"
    @Published var cadenceRunning = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?

    // cadence test state
    private var csv: CSVWriter?
    private var framesWanted = 0
    private var framesDone = 0
    private var lastFinish: Date?
    private var testStart: Date?
    private var useRAW = false

    private override init() { super.init() }

    func requestAndStart() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorized = granted
        guard granted else { statusLine = "camera permission denied"; return }
        configure()
    }

    private func configure() {
        guard !sessionRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            statusLine = "camera setup failed"
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .speed
        session.commitConfiguration()
        device = cam

        let s = session
        Task.detached { s.startRunning() }
        sessionRunning = true
        statusLine = "camera running"
    }

    /// Lock 1 s (or format max) custom exposure at the given ISO.
    private func lockAstroExposure(iso: Float) {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            let maxDur = dev.activeFormat.maxExposureDuration
            let oneSec = CMTime(value: 1, timescale: 1)
            let dur = CMTimeCompare(maxDur, oneSec) < 0 ? maxDur : oneSec
            let isoClamped = min(max(iso, dev.activeFormat.minISO), dev.activeFormat.maxISO)
            dev.setExposureModeCustom(duration: dur, iso: isoClamped, completionHandler: nil)
            if dev.isFocusModeSupported(.locked) {
                dev.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil)
            }
            dev.unlockForConfiguration()
            let seconds = CMTimeGetSeconds(dur)
            statusLine = String(format: "exposure locked: %.3f s @ ISO %.0f (format max %.3f s)",
                                seconds, isoClamped, CMTimeGetSeconds(maxDur))
        } catch {
            statusLine = "exposure lock failed: \(error.localizedDescription)"
        }
    }

    /// Shot-to-shot cadence test: N sequential captures (RAW if available),
    /// each fired from the previous one's completion.
    func runCadence(frames: Int, iso: Float, raw: Bool, responsive: Bool) {
        guard sessionRunning, !cadenceRunning else { return }
        cadenceRunning = true
        framesWanted = frames
        framesDone = 0
        lastFinish = nil
        testStart = Date()
        useRAW = raw

        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = responsive
        }
        if photoOutput.isZeroShutterLagSupported {
            photoOutput.isZeroShutterLagEnabled = responsive
        }

        lockAstroExposure(iso: iso)

        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
            .filter { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let rawAvailable = !rawTypes.isEmpty

        csv = BenchLog.shared.newCSV(
            test: "cadence",
            header: "frame,shot_to_shot_s,format,exposure_s,responsive,error")
        csv?.row(["config", "", raw && rawAvailable ? "bayer_raw" : "heic",
                  "", responsive ? "true" : "false",
                  "maxExposure=\(device.map { CMTimeGetSeconds($0.activeFormat.maxExposureDuration) } ?? 0)"])

        statusLine = "cadence: 0/\(frames)"
        fireNext(rawTypes: rawTypes)
    }

    private func fireNext(rawTypes: [OSType]) {
        let settings: AVCapturePhotoSettings
        if useRAW, let fmt = rawTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: fmt)
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .speed
        pendingRawTypes = rawTypes
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private var pendingRawTypes: [OSType] = []

    fileprivate func captureFinished(errorText: String?, exposureSeconds: Double?) {
        let now = Date()
        let delta = lastFinish.map { now.timeIntervalSince($0) }
        lastFinish = now
        framesDone += 1
        csv?.row(["\(framesDone)",
                  delta.map { String(format: "%.3f", $0) } ?? "",
                  useRAW ? "raw" : "heic",
                  exposureSeconds.map { String(format: "%.3f", $0) } ?? "",
                  "", errorText ?? ""])
        statusLine = "cadence: \(framesDone)/\(framesWanted)"

        if framesDone < framesWanted && cadenceRunning {
            fireNext(rawTypes: pendingRawTypes)
        } else {
            let total = testStart.map { Date().timeIntervalSince($0) } ?? 0
            let fps = total > 0 ? Double(framesDone) / total : 0
            csv?.row(["summary", String(format: "total_s=%.1f mean_s=%.3f", total,
                                        total / Double(max(framesDone, 1))), "", "", "",
                      String(format: "%.2f frames/s", fps)])
            csv?.close(); csv = nil
            cadenceRunning = false
            statusLine = String(format: "cadence done: %d frames, %.2f s/frame avg",
                                framesDone, total / Double(max(framesDone, 1)))
        }
    }

    func abortCadence() {
        cadenceRunning = false
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        // Extract achieved exposure from EXIF if present; discard pixel data.
        var exposure: Double?
        if let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let t = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            exposure = t
        }
        let errText = error?.localizedDescription
        Task { @MainActor in
            CameraService.shared.captureFinished(errorText: errText, exposureSeconds: exposure)
        }
    }
}
