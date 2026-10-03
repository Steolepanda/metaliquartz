@preconcurrency import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageImportPayload: Hashable, Sendable {
    var filename: String
    var data: Data
}

struct ImageDropFailure: Hashable, Sendable {
    var filename: String
    var reason: String
}

struct ImageDropRequest: Sendable {
    var location: GraphLocation
    var point: CanvasPoint
    var targetNodeID: NodeID?
    var payloads: [ImageImportPayload]
    var failures: [ImageDropFailure]
}

struct ImageImportMutationResult {
    var document: CompositionDocument
    var affectedNodeIDs: [NodeID]
}

enum ImageImportMutation {
    static func apply(
        payloads: [ImageImportPayload],
        to document: CompositionDocument,
        at location: GraphLocation,
        dropPoint: CanvasPoint,
        targetNodeID: NodeID?
    ) -> ImageImportMutationResult? {
        guard !payloads.isEmpty,
            let imageDefinition = PatchRegistry.definition(
                for: "\(PatchRegistry.namespace).image-file"
            ),
            var graph = document.composition.graph(at: location)
        else { return nil }

        var value = document
        var remainingPayloads = payloads[...]
        var affectedNodeIDs: [NodeID] = []
        var replacedAssetIDs = Set<UUID>()
        var layoutOrigin = dropPoint

        if let targetNodeID,
            let targetIndex = graph.nodes.firstIndex(where: {
                $0.id == targetNodeID && $0.patchType == imageDefinition.id
            }),
            let payload = remainingPayloads.popFirst()
        {
            if case .string(let oldID) = graph.nodes[targetIndex].parameters["assetID"],
                let oldAssetID = UUID(uuidString: oldID)
            {
                replacedAssetIDs.insert(oldAssetID)
            }
            let assetID = append(payload, to: &value)
            graph.nodes[targetIndex].parameters["assetID"] = .string(assetID.uuidString)
            affectedNodeIDs.append(targetNodeID)
            layoutOrigin = CanvasPoint(
                x: graph.nodes[targetIndex].position.x + 222,
                y: graph.nodes[targetIndex].position.y
            )
        }

        for (index, payload) in remainingPayloads.enumerated() {
            let column = index % 3
            let row = index / 3
            let position = CanvasPoint(
                x: layoutOrigin.x + Double(column) * 222,
                y: layoutOrigin.y + Double(row) * 126
            )
            var node = imageDefinition.makeNode(at: position)
            let assetID = append(payload, to: &value)
            node.parameters["assetID"] = .string(assetID.uuidString)
            graph.nodes.append(node)
            affectedNodeIDs.append(node.id)
        }

        guard !affectedNodeIDs.isEmpty else { return nil }
        value.composition.setGraph(graph, at: location)
        let previousState = value.composition.editorState(at: location) ?? .default
        value.composition.setEditorState(
            EditorStateRecord(
                viewport: previousState.viewport,
                selectedNodeIDs: affectedNodeIDs
            ),
            at: location
        )
        removeUnreferencedAssets(replacedAssetIDs, from: &value)
        value.composition.metadata.modifiedAt = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        )
        return ImageImportMutationResult(
            document: value,
            affectedNodeIDs: affectedNodeIDs
        )
    }

    private static func append(
        _ payload: ImageImportPayload,
        to document: inout CompositionDocument
    ) -> UUID {
        let assetID = UUID()
        let originalFilename = sanitizedFilename(payload.filename)
        let storedFilename = "\(assetID.uuidString)-\(originalFilename)"
        document.assets[storedFilename] = payload.data
        document.composition.assets.append(
            AssetReference(
                id: assetID,
                filename: storedFilename,
                originalFilename: originalFilename,
                mediaType: AssetMediaKind.image.rawValue
            )
        )
        return assetID
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/\\")
        )
        let components = filename.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? "_" : String(scalar)
        }
        let result = components.joined()
        return result.isEmpty ? "Dropped Image" : result
    }

    private static func removeUnreferencedAssets(
        _ candidateIDs: Set<UUID>,
        from document: inout CompositionDocument
    ) {
        guard !candidateIDs.isEmpty else { return }
        let graphs =
            [document.composition.graph]
            + document.composition.macroDefinitions.map(\.graph)
        let referencedIDs = Set(
            graphs.flatMap(\.nodes).compactMap { node -> UUID? in
                guard case .string(let value) = node.parameters["assetID"] else {
                    return nil
                }
                return UUID(uuidString: value)
            }
        )
        let removableIDs = candidateIDs.subtracting(referencedIDs)
        let removableFiles = Set(
            document.composition.assets.compactMap { asset in
                removableIDs.contains(asset.id) ? asset.filename : nil
            }
        )
        document.composition.assets.removeAll { removableIDs.contains($0.id) }
        for filename in removableFiles {
            document.assets.removeValue(forKey: filename)
        }
    }
}

@MainActor
enum ImageDropResolver {
    static let readableTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        types.append(
            contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType(rawValue: $0)
            }
        )
        return Array(Set(types))
    }()

    static func canResolveImages(from pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: imageURLReadingOptions
        ) {
            return true
        }
        let receivers =
            pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self],
                options: nil
            ) as? [NSFilePromiseReceiver] ?? []
        if receivers.contains(where: { receiver in
            receiver.fileTypes.isEmpty
                || receiver.fileTypes.contains { identifier in
                    UTType(identifier)?.conforms(to: .image) == true
                }
        }) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    static func resolve(
        pasteboard: NSPasteboard,
        completion: @escaping @MainActor ([ImageImportPayload], [ImageDropFailure]) -> Void
    ) {
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: imageURLReadingOptions
            ) as? [URL] ?? []
        if !urls.isEmpty {
            resolve(urls: urls, completion: completion)
            return
        }

        let receivers =
            pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self],
                options: nil
            ) as? [NSFilePromiseReceiver] ?? []
        let imageReceivers = receivers.filter { receiver in
            receiver.fileTypes.isEmpty
                || receiver.fileTypes.contains { identifier in
                    UTType(identifier)?.conforms(to: .image) == true
                }
        }
        if !imageReceivers.isEmpty {
            resolve(receivers: imageReceivers, completion: completion)
            return
        }

        var payloads: [ImageImportPayload] = []
        var failures: [ImageDropFailure] = []
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            let data: Data
            let pathExtension: String
            if let png = item.data(forType: .png) {
                data = png
                pathExtension = "png"
            } else if let tiff = item.data(forType: .tiff) {
                data = tiff
                pathExtension = "tiff"
            } else {
                continue
            }
            let filename = "Dropped Image \(index + 1).\(pathExtension)"
            switch validatedPayload(filename: filename, data: data) {
            case .success(let payload): payloads.append(payload)
            case .failure(let error): failures.append(error.failure)
            }
        }
        completion(payloads, failures)
    }

    nonisolated static func validatedPayload(
        filename: String,
        data: Data
    ) -> Result<ImageImportPayload, ImageDropValidationError> {
        guard data.count <= 256 * 1_024 * 1_024 else {
            return .failure(
                ImageDropValidationError(
                    failure: ImageDropFailure(
                        filename: filename,
                        reason: "The image is larger than the 256 MB import limit."
                    )
                )
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
        else {
            return .failure(
                ImageDropValidationError(
                    failure: ImageDropFailure(
                        filename: filename,
                        reason: "The data is not a supported still image."
                    )
                )
            )
        }
        return .success(ImageImportPayload(filename: filename, data: data))
    }

    private static let imageURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    private static func resolve(
        urls: [URL],
        completion: @escaping @MainActor ([ImageImportPayload], [ImageDropFailure]) -> Void
    ) {
        Task {
            var payloads: [ImageImportPayload] = []
            var failures: [ImageDropFailure] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    switch validatedPayload(filename: url.lastPathComponent, data: data) {
                    case .success(let payload): payloads.append(payload)
                    case .failure(let error): failures.append(error.failure)
                    }
                } catch {
                    failures.append(
                        ImageDropFailure(
                            filename: url.lastPathComponent,
                            reason: error.localizedDescription
                        )
                    )
                }
            }
            completion(payloads, failures)
        }
    }

    private static func resolve(
        receivers: [NSFilePromiseReceiver],
        completion: @escaping @MainActor ([ImageImportPayload], [ImageDropFailure]) -> Void
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MetaliquartzDrops-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            completion(
                [],
                [ImageDropFailure(filename: "Photos", reason: error.localizedDescription)]
            )
            return
        }

        let expectedCount = receivers.reduce(0) { result, receiver in
            result + max(1, receiver.fileNames.count)
        }
        let accumulator = FilePromiseAccumulator(
            remaining: expectedCount,
            directory: directory,
            completion: completion
        )
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: directory,
                options: [:],
                operationQueue: .main
            ) { url, error in
                accumulator.receive(url: url, error: error)
            }
        }
    }
}

struct ImageDropValidationError: Error {
    var failure: ImageDropFailure
}

@MainActor
private final class FilePromiseAccumulator {
    private var remaining: Int
    private let directory: URL
    private let completion: @MainActor ([ImageImportPayload], [ImageDropFailure]) -> Void
    private var payloads: [ImageImportPayload] = []
    private var failures: [ImageDropFailure] = []

    init(
        remaining: Int,
        directory: URL,
        completion: @escaping @MainActor ([ImageImportPayload], [ImageDropFailure]) -> Void
    ) {
        self.remaining = remaining
        self.directory = directory
        self.completion = completion
    }

    func receive(url: URL, error: Error?) {
        defer { finishOne() }
        if let error {
            failures.append(
                ImageDropFailure(
                    filename: url.lastPathComponent, reason: error.localizedDescription)
            )
            return
        }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            switch ImageDropResolver.validatedPayload(
                filename: url.lastPathComponent,
                data: data
            ) {
            case .success(let payload): payloads.append(payload)
            case .failure(let error): failures.append(error.failure)
            }
        } catch {
            failures.append(
                ImageDropFailure(
                    filename: url.lastPathComponent,
                    reason: error.localizedDescription
                )
            )
        }
    }

    private func finishOne() {
        remaining -= 1
        guard remaining <= 0 else { return }
        try? FileManager.default.removeItem(at: directory)
        completion(payloads, failures)
    }
}
