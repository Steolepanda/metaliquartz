import SwiftUI
import UniformTypeIdentifiers

enum CompositionDocumentError: LocalizedError {
    case expectedPackage
    case missingComposition
    case unreadableComposition(String)
    case unsafePackageEntry(String)

    var errorDescription: String? {
        switch self {
        case .expectedPackage:
            "This file is not a Metaliquartz package. Choose a folder ending in .mquartz."
        case .missingComposition:
            "The package is missing composition.json. Restore it from a recovery snapshot or backup."
        case .unreadableComposition(let detail):
            "composition.json could not be opened: \(detail)"
        case .unsafePackageEntry(let name):
            "The package contains an unsafe file name: \(name)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .expectedPackage:
            "Open a valid .mquartz package."
        case .missingComposition, .unreadableComposition:
            "Keep the damaged package unchanged, then try its recovery snapshot or a backup copy."
        case .unsafePackageEntry:
            "Remove entries containing path separators or parent-directory components."
        }
    }
}

extension UTType {
    static let metaliquartzComposition = UTType(
        exportedAs: CompositionFile.formatIdentifier,
        conformingTo: .package
    )
}

struct CompositionDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.metaliquartzComposition]

    var composition: CompositionFile
    var assets: [String: Data]
    var shaders: [String: Data]
    var thumbnail: Data?

    init(
        composition: CompositionFile = .empty(),
        assets: [String: Data] = [:],
        shaders: [String: Data] = [:],
        thumbnail: Data? = nil
    ) {
        self.composition = composition
        self.assets = assets
        self.shaders = shaders
        self.thumbnail = thumbnail
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(packageWrapper: configuration.file)
    }

    init(packageWrapper: FileWrapper) throws {
        guard packageWrapper.isDirectory else {
            throw CompositionDocumentError.expectedPackage
        }
        guard
            let wrappers = packageWrapper.fileWrappers,
            let compositionData = wrappers["composition.json"]?.regularFileContents
        else {
            throw CompositionDocumentError.missingComposition
        }

        try Self.validatePackageEntries(wrappers)

        do {
            composition = try CompositionCodec.decode(compositionData)
        } catch {
            ApplicationHealthStore.record(
                category: "document",
                message: "Could not decode a composition package",
                error: error
            )
            throw CompositionDocumentError.unreadableComposition(error.localizedDescription)
        }
        assets = Self.readRegularFiles(from: wrappers["Assets"])
        shaders = Self.readRegularFiles(from: wrappers["Shaders"])
        thumbnail = wrappers["Thumbnail.png"]?.regularFileContents
        Self.hydrateShaders(in: &composition.graph, files: shaders)
        if var definitions = composition.macros {
            for index in definitions.indices {
                Self.hydrateShaders(in: &definitions[index].graph, files: shaders)
            }
            composition.macros = definitions
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try makePackageWrapper()
    }

    func makePackageWrapper() throws -> FileWrapper {
        var compositionForWriting = composition
        var shaderFiles = shaders
        Self.externalizeShaders(in: &compositionForWriting.graph, files: &shaderFiles)
        if var definitions = compositionForWriting.macros {
            for index in definitions.indices {
                Self.externalizeShaders(
                    in: &definitions[index].graph,
                    files: &shaderFiles
                )
            }
            compositionForWriting.macros = definitions
        }
        let compositionWrapper = FileWrapper(
            regularFileWithContents: try CompositionCodec.encode(compositionForWriting)
        )
        compositionWrapper.preferredFilename = "composition.json"

        var children: [String: FileWrapper] = [
            "composition.json": compositionWrapper,
            "Assets": Self.directoryWrapper(files: assets),
            "Shaders": Self.directoryWrapper(files: shaderFiles),
        ]
        if let thumbnail {
            let wrapper = FileWrapper(regularFileWithContents: thumbnail)
            wrapper.preferredFilename = "Thumbnail.png"
            children["Thumbnail.png"] = wrapper
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    private static func directoryWrapper(files: [String: Data]) -> FileWrapper {
        FileWrapper(
            directoryWithFileWrappers: files.mapValues { FileWrapper(regularFileWithContents: $0) }
        )
    }

    private static func readRegularFiles(from wrapper: FileWrapper?) -> [String: Data] {
        guard let wrappers = wrapper?.fileWrappers else { return [:] }
        return wrappers.reduce(into: [:]) { result, entry in
            if let data = entry.value.regularFileContents {
                result[entry.key] = data
            }
        }
    }

    private static func validatePackageEntries(_ wrappers: [String: FileWrapper]) throws {
        for (name, wrapper) in wrappers {
            try validateEntryName(name)
            if wrapper.isDirectory, let children = wrapper.fileWrappers {
                try validatePackageEntries(children)
            }
        }
    }

    private static func validateEntryName(_ name: String) throws {
        guard !name.isEmpty,
            name != ".",
            name != "..",
            !name.contains("/"),
            !name.contains("\\"),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw CompositionDocumentError.unsafePackageEntry(name)
        }
    }

    private static func hydrateShaders(
        in graph: inout GraphRecord,
        files: [String: Data]
    ) {
        for index in graph.nodes.indices {
            guard
                PatchRegistry.definition(for: graph.nodes[index].patchType)?.executorKind
                    == .customShader,
                let filename = graph.nodes[index].configuration["shaderFile"]?.stringValue,
                let data = files[filename],
                let source = String(data: data, encoding: .utf8)
            else { continue }
            graph.nodes[index].parameters["shaderSource"] = .string(source)
        }
    }

    private static func externalizeShaders(
        in graph: inout GraphRecord,
        files: inout [String: Data]
    ) {
        for index in graph.nodes.indices {
            let node = graph.nodes[index]
            guard
                PatchRegistry.definition(for: node.patchType)?.executorKind == .customShader,
                case .string(let source) = node.parameters["shaderSource"]
            else { continue }
            let filename =
                node.configuration["shaderFile"]?.stringValue
                ?? "\(node.id.rawValue.uuidString).metal"
            files[filename] = Data(source.utf8)
            graph.nodes[index].configuration["shaderFile"] = .string(filename)
            graph.nodes[index].parameters.removeValue(forKey: "shaderSource")
        }
    }
}

extension JSONValue {
    fileprivate var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
