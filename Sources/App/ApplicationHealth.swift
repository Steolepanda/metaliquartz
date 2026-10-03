import AppKit
import Darwin
import Foundation
import OSLog

enum ApplicationHealthStore {
    private static let lock = NSLock()
    private static let logger = Logger(
        subsystem: "com.steolepanda.Metaliquartz",
        category: "application"
    )

    static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("Metaliquartz/Logs", isDirectory: true)
    }

    @discardableResult
    static func beginLaunch(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let directory = try directory ?? defaultDirectory(fileManager: fileManager)
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousLaunchWasUnclean =
            staleMarkers(
                in: directory,
                fileManager: fileManager
            ).isEmpty == false
        if previousLaunchWasUnclean {
            append(
                "Previous launch did not shut down cleanly; recovery snapshots may be available.",
                category: "lifecycle",
                directory: directory,
                fileManager: fileManager
            )
        }
        try Data().write(
            to: markerURL(
                in: directory,
                processID: ProcessInfo.processInfo.processIdentifier
            ),
            options: .atomic
        )
        return previousLaunchWasUnclean
    }

    static func endLaunch(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        guard let directory = try? directory ?? defaultDirectory(fileManager: fileManager) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(
            at: markerURL(
                in: directory,
                processID: ProcessInfo.processInfo.processIdentifier
            )
        )
    }

    static func record(
        category: String,
        message: String,
        error: Error? = nil,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let detail = error.map { "\(message): \($0.localizedDescription)" } ?? message
        if error == nil {
            logger.notice("[\(category, privacy: .public)] \(detail, privacy: .public)")
        } else {
            logger.error("[\(category, privacy: .public)] \(detail, privacy: .public)")
        }
        guard let directory = try? directory ?? defaultDirectory(fileManager: fileManager) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        append(
            detail,
            category: category,
            directory: directory,
            fileManager: fileManager
        )
    }

    static func diagnosticReport(
        renderSnapshot: RenderDiagnosticsSnapshot? = nil,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> String {
        let directory = try? directory ?? defaultDirectory(fileManager: fileManager)
        let log = directory.flatMap { try? String(contentsOf: logURL(in: $0), encoding: .utf8) }
        var lines = [
            "Metaliquartz Alpha Diagnostic Report",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: arm64",
        ]
        if let renderSnapshot {
            lines += [
                "Frames: \(renderSnapshot.totalFrames)",
                "Dropped: \(renderSnapshot.droppedFrames)",
                "Dropped percent: \(String(format: "%.3f", renderSnapshot.droppedFramePercentage))",
                "CPU frame ms: \(String(format: "%.3f", renderSnapshot.cpuFrameMilliseconds))",
                "GPU frame ms: \(String(format: "%.3f", renderSnapshot.gpuFrameMilliseconds))",
                "p95 frame ms: \(String(format: "%.3f", renderSnapshot.p95FrameMilliseconds))",
                "Texture pool: \(renderSnapshot.texturePool.inUse) in use / \(renderSnapshot.texturePool.totalAllocated) allocated",
                "Node errors: \(renderSnapshot.nodeErrors.count)",
            ]
        }
        lines.append("\nRecent structured log:\n\(log ?? "No log entries.")")
        return lines.joined(separator: "\n")
    }

    @discardableResult
    static func exportDiagnosticReport(
        renderSnapshot: RenderDiagnosticsSnapshot,
        to url: URL
    ) throws -> URL {
        try Data(diagnosticReport(renderSnapshot: renderSnapshot).utf8).write(
            to: url,
            options: .atomic
        )
        return url
    }

    private static func append(
        _ message: String,
        category: String,
        directory: URL,
        fileManager: FileManager
    ) {
        let line =
            "\(ISO8601DateFormatter().string(from: Date())) [\(category)] \(message)\n"
        let url = logURL(in: directory)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > 1_000_000
        {
            let previous = directory.appendingPathComponent("metaliquartz.previous.log")
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: url, to: previous)
        }
        if !fileManager.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            logger.error("Could not append the local diagnostic log")
        }
    }

    private static func staleMarkers(
        in directory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let entries =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        return entries.filter { url in
            guard url.lastPathComponent.hasPrefix("running-"),
                url.pathExtension == "marker",
                let processID = Int32(url.deletingPathExtension().lastPathComponent.dropFirst(8))
            else { return false }
            guard !processIsAlive(processID) else { return false }
            try? fileManager.removeItem(at: url)
            return true
        }
    }

    private static func processIsAlive(_ processID: Int32) -> Bool {
        Darwin.kill(processID, 0) == 0 || errno == EPERM
    }

    private static func markerURL(in directory: URL, processID: Int32) -> URL {
        directory.appendingPathComponent("running-\(processID).marker")
    }

    private static func logURL(in directory: URL) -> URL {
        directory.appendingPathComponent("metaliquartz.log")
    }
}

@MainActor
final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSSetUncaughtExceptionHandler { exception in
            ApplicationHealthStore.record(
                category: "uncaught-exception",
                message: "\(exception.name.rawValue): \(exception.reason ?? "No reason supplied")"
            )
        }
        do {
            if try ApplicationHealthStore.beginLaunch() {
                ApplicationHealthStore.record(
                    category: "recovery",
                    message: "Detected an unclean previous shutdown"
                )
            }
        } catch {
            ApplicationHealthStore.record(
                category: "lifecycle",
                message: "Could not create the launch marker",
                error: error
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ApplicationHealthStore.endLaunch()
    }
}
