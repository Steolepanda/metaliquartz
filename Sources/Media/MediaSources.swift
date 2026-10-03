@preconcurrency import AVFoundation
import CoreVideo
import Foundation
@preconcurrency import Metal

struct PlaybackTransportState: Hashable, Sendable {
    var isPlaying = true
    var resetToken = 0
}

enum EmbeddedMediaCache {
    static func fileURL(assetID: UUID, filename: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetaliquartzMedia", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let pathExtension = URL(fileURLWithPath: filename).pathExtension
        let cachedName =
            pathExtension.isEmpty
            ? assetID.uuidString
            : "\(assetID.uuidString).\(pathExtension)"
        let url = directory.appendingPathComponent(cachedName, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }
}

@MainActor
final class MovieFrameSource: NSObject {
    private let player: AVPlayer
    private let videoOutput: AVPlayerItemVideoOutput
    private var loops = true

    init(assetID: UUID, filename: String, data: Data, loops: Bool) throws {
        let url = try EmbeddedMediaCache.fileURL(
            assetID: assetID,
            filename: filename,
            data: data
        )
        let item = AVPlayerItem(url: url)
        videoOutput = AVPlayerItemVideoOutput(
            pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        item.add(videoOutput)
        player = AVPlayer(playerItem: item)
        self.loops = loops
        super.init()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    func setPlaying(_ playing: Bool) {
        if playing {
            player.play()
        } else {
            player.pause()
        }
    }

    func setLoops(_ loops: Bool) {
        self.loops = loops
    }

    func seekToStart() {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func copyCurrentPixelBuffer() -> CVPixelBuffer? {
        let time = player.currentTime()
        return videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }

    @objc private func itemDidReachEnd(_ notification: Notification) {
        guard loops else { return }
        seekToStart()
        player.play()
    }
}

final class CameraFrameSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.steolepanda.metaliquartz.camera")
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var hasStarted = false

    func startIfNeeded(deviceID: String?) {
        frameLock.lock()
        let shouldStart = !hasStarted
        hasStarted = true
        frameLock.unlock()
        guard shouldStart else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(deviceID: deviceID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.configureAndStart(deviceID: deviceID) }
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func stop() {
        frameLock.lock()
        let shouldStop = hasStarted
        hasStarted = false
        latestFrame = nil
        frameLock.unlock()
        guard shouldStop else { return }
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func copyLatestPixelBuffer() -> CVPixelBuffer? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        latestFrame = pixelBuffer
        frameLock.unlock()
    }

    private func configureAndStart(deviceID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let device: AVCaptureDevice?
            if let deviceID, !deviceID.isEmpty {
                device = AVCaptureDevice(uniqueID: deviceID)
            } else {
                device = AVCaptureDevice.default(for: .video)
            }
            guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }

            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: sessionQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            session.startRunning()
        }
    }
}

final class MediaTextureFrame: @unchecked Sendable {
    let texture: MTLTexture
    private let backing: CVMetalTexture

    init(texture: MTLTexture, backing: CVMetalTexture) {
        self.texture = texture
        self.backing = backing
    }
}

final class PixelBufferTextureConverter {
    private var cache: CVMetalTextureCache?

    init(device: MTLDevice) {
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func makeTexture(from pixelBuffer: CVPixelBuffer) -> MediaTextureFrame? {
        guard let cache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var backing: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &backing
        )
        guard result == kCVReturnSuccess,
            let backing,
            let texture = CVMetalTextureGetTexture(backing)
        else { return nil }
        return MediaTextureFrame(texture: texture, backing: backing)
    }
}

@MainActor
final class MetalMediaSourceManager {
    private let converter: PixelBufferTextureConverter
    private var movieSources: [UUID: MovieFrameSource] = [:]
    private let cameraSource = CameraFrameSource()
    private var transport = PlaybackTransportState()

    init(device: MTLDevice) {
        converter = PixelBufferTextureConverter(device: device)
    }

    func update(
        composition: CompositionFile,
        assets: [String: Data],
        transport newTransport: PlaybackTransportState
    ) {
        let movieNodes = composition.graph.nodes.filter {
            PatchRegistry.definition(for: $0.patchType)?.executorKind == .movieImage
        }
        var activeAssetIDs = Set<UUID>()
        for node in movieNodes {
            guard
                let idString = node.parameters.string("assetID"),
                let assetID = UUID(uuidString: idString),
                let reference = composition.assets.first(where: { $0.id == assetID }),
                let data = assets[reference.filename]
            else { continue }
            activeAssetIDs.insert(assetID)
            if movieSources[assetID] == nil {
                movieSources[assetID] = try? MovieFrameSource(
                    assetID: assetID,
                    filename: reference.originalFilename,
                    data: data,
                    loops: node.parameters.boolean("loop", default: true)
                )
            }
            movieSources[assetID]?.setLoops(node.parameters.boolean("loop", default: true))
            movieSources[assetID]?.setPlaying(newTransport.isPlaying)
        }
        movieSources = movieSources.filter { activeAssetIDs.contains($0.key) }

        if newTransport.resetToken != transport.resetToken {
            for source in movieSources.values { source.seekToStart() }
        }
        transport = newTransport

        if let cameraNode = composition.graph.nodes.first(where: {
            PatchRegistry.definition(for: $0.patchType)?.executorKind == .cameraImage
        }) {
            cameraSource.startIfNeeded(deviceID: cameraNode.parameters.string("deviceID"))
        } else {
            cameraSource.stop()
        }
    }

    func frame(for node: NodeRecord) -> MediaTextureFrame? {
        guard let kind = PatchRegistry.definition(for: node.patchType)?.executorKind else {
            return nil
        }
        let pixelBuffer: CVPixelBuffer?
        switch kind {
        case .movieImage:
            guard
                let idString = node.parameters.string("assetID"),
                let assetID = UUID(uuidString: idString)
            else { return nil }
            pixelBuffer = movieSources[assetID]?.copyCurrentPixelBuffer()
        case .cameraImage:
            pixelBuffer = cameraSource.copyLatestPixelBuffer()
        default:
            return nil
        }
        guard let pixelBuffer else { return nil }
        return converter.makeTexture(from: pixelBuffer)
    }
}

extension Dictionary where Key == String, Value == ParameterValue {
    fileprivate func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    fileprivate func boolean(_ key: String, default fallback: Bool = false) -> Bool {
        guard case .boolean(let value) = self[key] else { return fallback }
        return value
    }
}
