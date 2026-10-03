import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Observation

enum PermissionReadiness: String, Sendable {
    case ready = "Ready"
    case notDetermined = "Not requested"
    case denied = "Needs permission"
    case restricted = "Restricted"
}

struct PermissionGuidanceItem: Identifiable, Sendable {
    var id: String
    var name: String
    var readiness: PermissionReadiness
    var guidance: String
    var settingsPane: String?
}

@MainActor
@Observable
final class PermissionGuidanceModel {
    private(set) var items: [PermissionGuidanceItem] = []

    init() {
        refresh()
    }

    func refresh() {
        items = [cameraItem(), screenRecordingItem(), externalAccessItem()]
    }

    func requestCamera() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            refresh()
        }
    }

    func openSettings(for item: PermissionGuidanceItem) {
        guard let pane = item.settingsPane,
            let url = URL(string: "x-apple.systempreferences:\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func cameraItem() -> PermissionGuidanceItem {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let readiness: PermissionReadiness
        switch status {
        case .authorized: readiness = .ready
        case .notDetermined: readiness = .notDetermined
        case .denied: readiness = .denied
        case .restricted: readiness = .restricted
        @unknown default: readiness = .restricted
        }
        return PermissionGuidanceItem(
            id: "camera",
            name: "Camera",
            readiness: readiness,
            guidance:
                readiness == .ready
                ? "Camera patches can receive live frames."
                : "Allow camera access for live Camera patches.",
            settingsPane: "com.apple.preference.security?Privacy_Camera"
        )
    }

    private func screenRecordingItem() -> PermissionGuidanceItem {
        let ready = CGPreflightScreenCaptureAccess()
        return PermissionGuidanceItem(
            id: "screen-recording",
            name: "Screen Recording",
            readiness: ready ? .ready : .denied,
            guidance:
                ready
                ? "Screen capture access is available for future capture patches."
                : "Enable access before using screen capture sources.",
            settingsPane: "com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    private func externalAccessItem() -> PermissionGuidanceItem {
        PermissionGuidanceItem(
            id: "external-access",
            name: "Files, MIDI, OSC & Syphon",
            readiness: .ready,
            guidance:
                "App Sandbox is disabled; external media, MIDI, UDP control, and Syphon are available.",
            settingsPane: nil
        )
    }
}
