import Foundation
import ImageIO
@preconcurrency import MetalKit
import simd

struct TexturePoolKey: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: MTLPixelFormat
}

struct TexturePoolStats: Hashable, Sendable {
    var totalAllocated: Int
    var available: Int

    var inUse: Int { max(0, totalAllocated - available) }
}

final class TexturePool: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var available: [TexturePoolKey: [MTLTexture]] = [:]
    private var totalAllocated = 0

    init(device: MTLDevice) {
        self.device = device
    }

    func acquire(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        let key = TexturePoolKey(width: width, height: height, pixelFormat: pixelFormat)
        lock.lock()
        if var textures = available[key], let texture = textures.popLast() {
            available[key] = textures
            lock.unlock()
            return texture
        }
        lock.unlock()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = device.makeTexture(descriptor: descriptor)
        if texture != nil {
            lock.lock()
            totalAllocated += 1
            lock.unlock()
        }
        texture?.label = "Metaliquartz Pooled \(width)×\(height) Texture"
        return texture
    }

    func recycle(_ texture: MTLTexture) {
        let key = TexturePoolKey(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
        lock.lock()
        available[key, default: []].append(texture)
        lock.unlock()
    }

    func availableCount(for key: TexturePoolKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return available[key, default: []].count
    }

    func stats() -> TexturePoolStats {
        lock.lock()
        defer { lock.unlock() }
        return TexturePoolStats(
            totalAllocated: totalAllocated,
            available: available.values.reduce(0) { $0 + $1.count }
        )
    }
}

@MainActor
final class MetalImageRenderer {
    struct TransformUniforms {
        var translation: SIMD2<Float>
        var scale: Float
        var rotation: Float
        var opacity: Float
    }

    struct PreviewUniforms {
        var sourceSize: SIMD2<Float>
        var destinationSize: SIMD2<Float>
    }

    let device: MTLDevice
    let texturePool: TexturePool
    let transformPipeline: MTLRenderPipelineState
    let previewPipeline: MTLRenderPipelineState
    let imageEffects: MetalImageEffects
    let geometryRenderer: GeometryRenderer
    let feedbackStore: FeedbackTextureStore
    let syphonBridge: SyphonMetalBridge

    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private let mediaManager: MetalMediaSourceManager
    private var graph = GraphRecord.empty
    private var macros: [MacroDefinitionRecord] = []
    private var schedule: GraphSchedule?
    private var controlRuntime: GraphRuntime?
    private var assetReferences: [AssetReference] = []
    private var assetData: [String: Data] = [:]
    private var loadedTextures: [UUID: MTLTexture] = [:]
    private var feedbackResetToken = 0

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        texturePool = TexturePool(device: device)
        textureLoader = MTKTextureLoader(device: device)
        mediaManager = MetalMediaSourceManager(device: device)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MetalPreviewRendererError.commandQueueUnavailable
        }
        self.sampler = sampler

        transformPipeline = try Self.makePipeline(
            device: device,
            library: library,
            fragmentName: "transform2DFragment",
            pixelFormat: .rgba16Float,
            label: "Metaliquartz Transform 2D Pipeline"
        )
        previewPipeline = try Self.makePipeline(
            device: device,
            library: library,
            fragmentName: "texturePreviewFragment",
            pixelFormat: .bgra8Unorm_srgb,
            label: "Metaliquartz Texture Preview Pipeline"
        )
        imageEffects = try MetalImageEffects(
            device: device,
            defaultLibrary: library,
            texturePool: texturePool
        )
        geometryRenderer = try GeometryRenderer(
            device: device,
            library: library,
            texturePool: texturePool
        )
        feedbackStore = FeedbackTextureStore(device: device)
        syphonBridge = SyphonMetalBridge(device: device)
    }

    func update(
        composition: CompositionFile,
        assets: [String: Data],
        transport: PlaybackTransportState
    ) {
        if graph != composition.graph || macros != composition.macroDefinitions {
            graph = composition.graph
            macros = composition.macroDefinitions
            schedule = try? GraphCompiler.compile(
                composition.graph,
                macros: composition.macroDefinitions
            )
            controlRuntime = schedule.map { GraphRuntime(schedule: $0) }
        }
        assetReferences = composition.assets
        assetData = assets
        let validIDs = Set(composition.assets.map(\.id))
        loadedTextures = loadedTextures.filter { validIDs.contains($0.key) }
        let renderingGraph = schedule?.snapshot.graph ?? composition.graph
        let feedbackNodeIDs = Set(renderingGraph.nodes.filter { $0.breaksFrameCycle }.map(\.id))
        feedbackStore.retainOnly(nodeIDs: feedbackNodeIDs)
        if transport.resetToken != feedbackResetToken {
            feedbackResetToken = transport.resetToken
            feedbackStore.reset()
        }
        var renderingComposition = composition
        renderingComposition.graph = renderingGraph
        mediaManager.update(
            composition: renderingComposition,
            assets: assets,
            transport: transport
        )
        syphonBridge.update(composition: renderingComposition)
    }

    func encodeFrame(
        target: MTLTexture,
        drawableSize: CGSize,
        commandBuffer: MTLCommandBuffer,
        frame: FrameContext = FrameContext(time: 0, deltaTime: 0, frameIndex: 0)
    ) -> Bool {
        guard let schedule else { return false }
        let nodesByID = Dictionary(
            uniqueKeysWithValues: schedule.snapshot.graph.nodes.map { ($0.id, $0) }
        )
        var values: [PortAddress: MTLTexture] = [:]
        var temporaryTextures: [MTLTexture] = []
        var mediaFrames: [MediaTextureFrame] = []
        var previewTexture: MTLTexture?
        var consumerLayers: [(layer: Double, blending: String, texture: MTLTexture)] = []
        let controlEvaluation = controlRuntime?.evaluate(context: frame)
        let feedbackNodes = schedule.snapshot.graph.nodes.filter { node in
            PatchRegistry.definition(for: node.patchType)?.executorKind == .feedback
                && !node.isDisabled
        }

        for node in feedbackNodes {
            if node.parameters.boolean("clear") {
                feedbackStore.remove(nodeID: node.id)
            } else if let texture = feedbackStore.texture(for: node.id) {
                values[PortAddress(nodeID: node.id, portKey: "image")] = texture
            }
        }

        for scheduledNode in schedule.nodes {
            guard
                let storedNode = nodesByID[scheduledNode.nodeID],
                let definition = PatchRegistry.definition(for: storedNode.patchType),
                !storedNode.isDisabled
            else { continue }
            let node = effectiveNode(
                storedNode,
                scheduledNode: scheduledNode,
                nodesByID: nodesByID,
                evaluation: controlEvaluation
            )

            switch definition.executorKind {
            case .syphonInput:
                if let texture = syphonBridge.inputTexture(for: node) {
                    values[PortAddress(nodeID: node.id, portKey: "image")] = texture
                }
            case .unavailableImage:
                if let texture = imageTexture(for: node) {
                    values[PortAddress(nodeID: node.id, portKey: "image")] = texture
                }
            case .movieImage, .cameraImage:
                if let frame = mediaManager.frame(for: node) {
                    mediaFrames.append(frame)
                    values[PortAddress(nodeID: node.id, portKey: "image")] = frame.texture
                }
            case .transformImage:
                guard
                    let source = inputTexture(
                        key: "image",
                        node: node,
                        scheduledNode: scheduledNode,
                        nodesByID: nodesByID,
                        values: values
                    ),
                    let transformed = encodeTransform(
                        source: source,
                        parameters: node.parameters,
                        commandBuffer: commandBuffer
                    )
                else { continue }
                temporaryTextures.append(transformed)
                values[PortAddress(nodeID: node.id, portKey: "image")] = transformed
            case .colorControls, .blur, .glow, .customShader:
                guard
                    let source = inputTexture(
                        key: "image",
                        node: node,
                        scheduledNode: scheduledNode,
                        nodesByID: nodesByID,
                        values: values
                    )
                else { continue }
                let output: MTLTexture?
                switch definition.executorKind {
                case .colorControls:
                    output = imageEffects.encodeColorControls(
                        source: source,
                        parameters: node.parameters,
                        commandBuffer: commandBuffer
                    )
                case .blur:
                    output = imageEffects.encodeBlur(
                        source: source,
                        parameters: node.parameters,
                        commandBuffer: commandBuffer
                    )
                case .glow:
                    output = imageEffects.encodeGlow(
                        source: source,
                        parameters: node.parameters,
                        commandBuffer: commandBuffer
                    )
                case .customShader:
                    output = imageEffects.encodeCustomShader(
                        node: node,
                        source: source,
                        frame: frame,
                        commandBuffer: commandBuffer
                    )
                default:
                    output = nil
                }
                guard let output else { continue }
                temporaryTextures.append(output)
                values[PortAddress(nodeID: node.id, portKey: "image")] = output
            case .colorInvert:
                guard
                    let source = inputTexture(
                        key: "image",
                        node: node,
                        scheduledNode: scheduledNode,
                        nodesByID: nodesByID,
                        values: values
                    ),
                    let output = imageEffects.encodeColorInvert(
                        source: source,
                        commandBuffer: commandBuffer
                    )
                else { continue }
                temporaryTextures.append(output)
                values[PortAddress(nodeID: node.id, portKey: "image")] = output
            case .linearGradient:
                if let output = imageEffects.encodeLinearGradient(
                    parameters: node.parameters,
                    width: max(1, Int(drawableSize.width)),
                    height: max(1, Int(drawableSize.height)),
                    commandBuffer: commandBuffer
                ) {
                    temporaryTextures.append(output)
                    values[PortAddress(nodeID: node.id, portKey: "image")] = output
                }
            case .blend:
                let background = inputTexture(
                    key: "background",
                    node: node,
                    scheduledNode: scheduledNode,
                    nodesByID: nodesByID,
                    values: values
                )
                let foreground = inputTexture(
                    key: "foreground",
                    node: node,
                    scheduledNode: scheduledNode,
                    nodesByID: nodesByID,
                    values: values
                )
                if let background, let foreground,
                    let output = imageEffects.encodeBlend(
                        background: background,
                        foreground: foreground,
                        parameters: node.parameters,
                        commandBuffer: commandBuffer
                    )
                {
                    temporaryTextures.append(output)
                    values[PortAddress(nodeID: node.id, portKey: "image")] = output
                } else if let available = foreground ?? background {
                    values[PortAddress(nodeID: node.id, portKey: "image")] = available
                }
            case .displace:
                guard
                    let source = inputTexture(
                        key: "image",
                        node: node,
                        scheduledNode: scheduledNode,
                        nodesByID: nodesByID,
                        values: values
                    ),
                    let displacement = inputTexture(
                        key: "displacement",
                        node: node,
                        scheduledNode: scheduledNode,
                        nodesByID: nodesByID,
                        values: values
                    ),
                    let output = imageEffects.encodeDisplace(
                        source: source,
                        displacement: displacement,
                        parameters: node.parameters,
                        commandBuffer: commandBuffer
                    )
                else { continue }
                temporaryTextures.append(output)
                values[PortAddress(nodeID: node.id, portKey: "image")] = output
            case .sprite, .meshDisplacement, .pointGrid, .lineGrid:
                guard
                    let source = inputTexture(
                        key: "image",
                        node: node,
                        scheduledNode: scheduledNode,
                        nodesByID: nodesByID,
                        values: values
                    ),
                    let output = geometryRenderer.encode(
                        kind: definition.executorKind,
                        node: node,
                        source: source,
                        commandBuffer: commandBuffer
                    )
                else { continue }
                temporaryTextures.append(output)
                values[PortAddress(nodeID: node.id, portKey: "image")] = output
            case .clear:
                guard node.parameters.boolean("enable", default: true),
                    let output = imageEffects.encodeSolidColor(
                        color: node.parameters["clearColor"]
                            ?? .color(red: 0, green: 0, blue: 0, alpha: 1),
                        width: max(1, Int(drawableSize.width)),
                        height: max(1, Int(drawableSize.height)),
                        commandBuffer: commandBuffer
                    )
                else { continue }
                temporaryTextures.append(output)
                consumerLayers.append(
                    (node.parameters.number("layer"), "replace", output)
                )
            case .renderGradient:
                guard node.parameters.boolean("enable", default: true),
                    let output = imageEffects.encodeRenderGradient(
                        parameters: node.parameters,
                        width: max(1, Int(drawableSize.width)),
                        height: max(1, Int(drawableSize.height)),
                        commandBuffer: commandBuffer
                    )
                else { continue }
                temporaryTextures.append(output)
                consumerLayers.append(
                    (node.parameters.number("layer"), "replace", output)
                )
            case .billboard, .qcSprite, .cube, .sphere, .particleSystem:
                guard node.parameters.boolean("enable", default: true) else { continue }
                var source = inputTexture(
                    key: definition.executorKind == .cube ? "frontImage" : "image",
                    node: node,
                    scheduledNode: scheduledNode,
                    nodesByID: nodesByID,
                    values: values
                )
                if source == nil {
                    source = imageEffects.encodeSolidColor(
                        color: node.parameters["tint"]
                            ?? node.parameters["frontColor"]
                            ?? .color(red: 1, green: 1, blue: 1, alpha: 1),
                        width: max(2, Int(drawableSize.width)),
                        height: max(2, Int(drawableSize.height)),
                        commandBuffer: commandBuffer
                    )
                    if let source { temporaryTextures.append(source) }
                }
                guard let source,
                    let output = geometryRenderer.encode(
                        kind: definition.executorKind,
                        node: geometryCompatibleNode(node),
                        source: source,
                        commandBuffer: commandBuffer
                    )
                else { continue }
                temporaryTextures.append(output)
                consumerLayers.append(
                    (
                        node.parameters.number("layer"),
                        node.parameters.string("blending") ?? "over",
                        output
                    )
                )
            case .feedback:
                continue
            case .passthroughImage:
                if let source = inputTexture(
                    key: "image",
                    node: node,
                    scheduledNode: scheduledNode,
                    nodesByID: nodesByID,
                    values: values
                ) {
                    values[PortAddress(nodeID: node.id, portKey: "image")] = source
                }
            case .previewOutput:
                previewTexture = inputTexture(
                    key: "image",
                    node: node,
                    scheduledNode: scheduledNode,
                    nodesByID: nodesByID,
                    values: values
                )
            case .syphonOutput:
                if let texture = inputTexture(
                    key: "image",
                    node: node,
                    scheduledNode: scheduledNode,
                    nodesByID: nodesByID,
                    values: values
                ) {
                    syphonBridge.publish(
                        texture: texture,
                        from: node,
                        commandBuffer: commandBuffer
                    )
                }
            default:
                continue
            }
        }

        let feedbackCaptures: [(NodeID, MTLTexture)] = feedbackNodes.compactMap { node in
            guard
                !node.parameters.boolean("clear"),
                let scheduledNode = schedule.nodes.first(where: { $0.nodeID == node.id }),
                let source = inputTexture(
                    key: "image",
                    node: node,
                    scheduledNode: scheduledNode,
                    nodesByID: nodesByID,
                    values: values
                )
            else { return nil }
            return (node.id, source)
        }

        if !consumerLayers.isEmpty {
            var composed: MTLTexture?
            for layer in consumerLayers.sorted(by: { $0.layer < $1.layer }) {
                if layer.blending == "replace" || composed == nil {
                    composed = layer.texture
                    continue
                }
                let mode = layer.blending == "add" ? "add" : "normal"
                if let background = composed,
                    let blended = imageEffects.encodeBlend(
                        background: background,
                        foreground: layer.texture,
                        parameters: ["mode": .string(mode), "opacity": .number(1)],
                        commandBuffer: commandBuffer
                    )
                {
                    temporaryTextures.append(blended)
                    composed = blended
                }
            }
            previewTexture = composed
        }

        if !temporaryTextures.isEmpty {
            let pool = texturePool
            let texturesToRecycle = temporaryTextures
            commandBuffer.addCompletedHandler { _ in
                for texture in texturesToRecycle {
                    pool.recycle(texture)
                }
            }
        }
        if !mediaFrames.isEmpty {
            let framesToRetain = mediaFrames
            commandBuffer.addCompletedHandler { _ in
                withExtendedLifetime(framesToRetain) {}
            }
        }
        if let previewTexture {
            encodePreview(
                source: previewTexture,
                target: target,
                drawableSize: drawableSize,
                commandBuffer: commandBuffer
            )
        }
        for (nodeID, source) in feedbackCaptures {
            feedbackStore.capture(
                nodeID: nodeID,
                source: source,
                commandBuffer: commandBuffer
            )
        }
        return previewTexture != nil
    }

    var integrationDiagnostics: [NodeID: String] {
        syphonBridge.diagnostics
    }

    func encodeTransform(
        source: MTLTexture,
        parameters: [String: ParameterValue],
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard
            let output = texturePool.acquire(
                width: source.width,
                height: source.height,
                pixelFormat: .rgba16Float
            )
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            texturePool.recycle(output)
            return nil
        }
        var uniforms = TransformUniforms(
            translation: SIMD2(
                Float(parameters.number("translationX")),
                Float(parameters.number("translationY"))
            ),
            scale: Float(parameters.number("scale", default: 1)),
            rotation: Float(parameters.number("rotation")),
            opacity: Float(parameters.number("opacity", default: 1))
        )
        encoder.label = "Transform 2D Encoder"
        encoder.setRenderPipelineState(transformPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<TransformUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return output
    }

    func encodePreview(
        source: MTLTexture,
        target: MTLTexture,
        drawableSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.01, 0.01, 0.015, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = PreviewUniforms(
            sourceSize: SIMD2(Float(source.width), Float(source.height)),
            destinationSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        )
        encoder.label = "Texture Preview Encoder"
        encoder.setRenderPipelineState(previewPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<PreviewUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func imageTexture(for node: NodeRecord) -> MTLTexture? {
        guard
            let assetIDString = node.parameters.string("assetID"),
            let assetID = UUID(uuidString: assetIDString),
            let reference = assetReferences.first(where: { $0.id == assetID }),
            let data = assetData[reference.filename]
        else { return nil }
        if let cached = loadedTextures[assetID] { return cached }
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
        ]
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let directTexture =
            orientation == 1
            ? try? textureLoader.newTexture(data: data, options: options)
            : nil
        let texture =
            directTexture
            ?? orientedTexture(
                source: source,
                properties: properties,
                options: options
            )
        guard let texture else { return nil }
        texture.label = reference.originalFilename
        loadedTextures[assetID] = texture
        return texture
    }

    private func orientedTexture(
        source: CGImageSource?,
        properties: [CFString: Any]?,
        options: [MTKTextureLoader.Option: Any]
    ) -> MTLTexture? {
        guard let source,
            let width = properties?[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties?[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                decodeOptions as CFDictionary
            )
        else { return nil }
        return try? textureLoader.newTexture(cgImage: image, options: options)
    }

    private func inputTexture(
        key: String,
        node: NodeRecord,
        scheduledNode: ScheduledNode,
        nodesByID: [NodeID: NodeRecord],
        values: [PortAddress: MTLTexture]
    ) -> MTLTexture? {
        guard
            let inputPort = node.ports.first(where: { $0.direction == .input && $0.key == key }),
            let connection = scheduledNode.incomingConnections.first(where: {
                $0.inputPortID == inputPort.id
            }),
            let sourceNode = nodesByID[connection.outputNodeID],
            let sourcePort = sourceNode.ports.first(where: { $0.id == connection.outputPortID })
        else { return nil }
        return values[PortAddress(nodeID: sourceNode.id, portKey: sourcePort.key)]
    }

    private func effectiveNode(
        _ node: NodeRecord,
        scheduledNode: ScheduledNode,
        nodesByID: [NodeID: NodeRecord],
        evaluation: GraphEvaluation?
    ) -> NodeRecord {
        guard let evaluation else { return node }
        var result = node
        for connection in scheduledNode.incomingConnections {
            guard
                let inputPort = node.ports.first(where: { $0.id == connection.inputPortID }),
                inputPort.dataType != .image,
                let sourceNode = nodesByID[connection.outputNodeID],
                let sourcePort = sourceNode.ports.first(where: {
                    $0.id == connection.outputPortID
                }),
                let value = evaluation.values[
                    PortAddress(nodeID: sourceNode.id, portKey: sourcePort.key)
                ],
                let parameter = value.parameterValue
            else { continue }
            result.parameters[inputPort.key] = parameter
        }
        return result
    }

    private func geometryCompatibleNode(_ node: NodeRecord) -> NodeRecord {
        var result = node
        if result.parameters["scale"] == nil {
            let width = result.parameters.number("width", default: 1)
            let height = result.parameters.number("height", default: 1)
            result.parameters["scale"] = .number((width + height) / 2)
        }
        if result.parameters["rotation"] == nil {
            result.parameters["rotation"] = result.parameters["rotationZ"] ?? .number(0)
        }
        if result.parameters["tint"] == nil {
            result.parameters["tint"] =
                result.parameters["frontColor"]
                ?? .color(red: 1, green: 1, blue: 1, alpha: 1)
        }
        if result.patchType == "\(PatchRegistry.namespace).qc.sphere" {
            result.parameters["columns"] = result.parameters["slices"] ?? .number(32)
            result.parameters["rows"] = result.parameters["stacks"] ?? .number(16)
        }
        if result.patchType == "\(PatchRegistry.namespace).qc.particle-system" {
            let count = min(100_000, max(1, Int(result.parameters.number("count", default: 1_000))))
            let side = ceil(sqrt(Double(count)))
            result.parameters["columns"] = .number(side)
            result.parameters["rows"] = .number(side)
            result.parameters["pointSize"] = result.parameters["sizeMax"] ?? .number(0.05)
        }
        return result
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        fragmentName: String,
        pixelFormat: MTLPixelFormat,
        label: String
    ) throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: "previewVertex") else {
            throw MetalPreviewRendererError.shaderFunctionUnavailable("previewVertex")
        }
        guard let fragment = library.makeFunction(name: fragmentName) else {
            throw MetalPreviewRendererError.shaderFunctionUnavailable(fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

extension RuntimeValue {
    fileprivate var parameterValue: ParameterValue? {
        switch self {
        case .number(let value): .number(value)
        case .boolean(let value): .boolean(value)
        case .string(let value): .string(value)
        case .color(let red, let green, let blue, let alpha):
            .color(red: red, green: green, blue: blue, alpha: alpha)
        case .image, .event: nil
        }
    }
}

extension Dictionary where Key == String, Value == ParameterValue {
    fileprivate func number(_ key: String, default fallback: Double = 0) -> Double {
        guard case .number(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    fileprivate func boolean(_ key: String, default fallback: Bool = false) -> Bool {
        guard case .boolean(let value) = self[key] else { return fallback }
        return value
    }
}
