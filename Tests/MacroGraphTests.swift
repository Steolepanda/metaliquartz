import AppKit
import MetalKit
import XCTest

@testable import Metaliquartz

@MainActor
final class MacroGraphTests: XCTestCase {
    func testSelectedGraphConvertsToMacroAndEvaluatesIdentically() throws {
        let fixture = makeControlFixture()
        let context = FrameContext(time: 1, deltaTime: 1.0 / 60.0, frameIndex: 60)
        let baseline = GraphRuntime(schedule: try GraphCompiler.compile(fixture.composition.graph))
            .evaluate(context: context)
        let result = try MacroConverter.convert(
            selection: [fixture.factor.id, fixture.math.id],
            in: fixture.composition,
            name: "Multiply"
        )
        let schedule = try GraphCompiler.compile(
            result.composition.graph,
            macros: result.composition.macroDefinitions
        )
        let converted = GraphRuntime(schedule: schedule).evaluate(context: context)

        XCTAssertEqual(number(baseline, node: fixture.sink, key: "result"), 42)
        XCTAssertEqual(number(converted, node: fixture.sink, key: "result"), 42)
        XCTAssertEqual(result.composition.macroDefinitions.count, 1)
        XCTAssertEqual(result.composition.macroDefinitions[0].ports.count, 2)
        XCTAssertEqual(result.composition.graph.nodes.count, 3)
        XCTAssertFalse(schedule.snapshot.graph.nodes.contains { $0.macroID != nil })
    }

    func testNestedMacroFlattensWithoutChangingResults() throws {
        let fixture = makeControlFixture()
        let inner = try MacroConverter.convert(
            selection: [fixture.factor.id, fixture.math.id],
            in: fixture.composition,
            name: "Inner"
        )
        let outer = try MacroConverter.convert(
            selection: [inner.instanceNodeID],
            in: inner.composition,
            name: "Outer"
        )

        let schedule = try GraphCompiler.compile(
            outer.composition.graph,
            macros: outer.composition.macroDefinitions
        )
        let evaluation = GraphRuntime(schedule: schedule).evaluate(
            context: FrameContext(time: 0, deltaTime: 0, frameIndex: 0)
        )

        XCTAssertEqual(outer.composition.macroDefinitions.count, 2)
        XCTAssertFalse(schedule.snapshot.graph.nodes.contains { $0.macroID != nil })
        XCTAssertEqual(number(evaluation, node: fixture.sink, key: "result"), 42)
    }

    func testRecursiveMacroReferenceIsRejected() throws {
        let id = MacroID()
        var definition = MacroDefinitionRecord(
            id: id,
            name: "Recursive",
            graph: .empty,
            editorState: .default,
            ports: []
        )
        definition.graph.nodes = [
            NodeRecord.macroInstance(definition: definition, position: .zero)
        ]
        let issues = MacroValidator.validate(rootGraph: .empty, macros: [definition])

        XCTAssertTrue(
            issues.contains {
                if case .recursiveReference = $0 { return true }
                return false
            }
        )
        XCTAssertThrowsError(try GraphCompiler.compile(.empty, macros: [definition]))
    }

    func testMalformedAndDuplicateMacroMetadataProducesDiagnostics() {
        let malformed = NodeRecord(
            patchType: NodeRecord.macroPatchType,
            name: "Broken Macro"
        )
        let id = MacroID()
        let first = MacroDefinitionRecord(
            id: id,
            name: "First",
            graph: .empty,
            editorState: .default,
            ports: []
        )
        let duplicate = MacroDefinitionRecord(
            id: id,
            name: "Duplicate",
            graph: .empty,
            editorState: .default,
            ports: []
        )

        let issues = MacroValidator.validate(
            rootGraph: GraphRecord(nodes: [malformed], connections: []),
            macros: [first, duplicate]
        )

        XCTAssertTrue(issues.contains(.malformedInstance(malformed.id)))
        XCTAssertTrue(issues.contains(.duplicateMacro(id)))
    }

    func testMacroRoundTripPreservesIndependentEditorLayoutAndCanBeDuplicated() throws {
        let fixture = makeControlFixture()
        var result = try MacroConverter.convert(
            selection: [fixture.factor.id, fixture.math.id],
            in: fixture.composition,
            name: "Reusable Multiply"
        )
        result.composition.macroDefinitions[0].editorState = EditorStateRecord(
            viewport: CanvasViewport(origin: CanvasPoint(x: 123.5, y: -77), zoom: 1.8),
            selectedNodeIDs: [fixture.math.id]
        )

        let decoded = try CompositionCodec.decode(CompositionCodec.encode(result.composition))
        let macro = try XCTUnwrap(decoded.macroDefinitions.first)
        let instance = try XCTUnwrap(
            decoded.graph.nodes.first { $0.id == result.instanceNodeID }
        )
        let duplicate = GraphClipboardPayload.selection(
            from: decoded.graph,
            nodeIDs: [instance.id]
        ).duplicated()
        var duplicatedGraph = decoded.graph
        duplicatedGraph.nodes.append(contentsOf: duplicate.nodes)

        XCTAssertEqual(macro.editorState.viewport.origin, CanvasPoint(x: 123.5, y: -77))
        XCTAssertEqual(macro.editorState.viewport.zoom, 1.8)
        XCTAssertEqual(duplicate.nodes.first?.macroID, macro.id)
        let expanded = try MacroExpander.expand(
            graph: duplicatedGraph,
            macros: decoded.macroDefinitions
        )
        XCTAssertEqual(expanded.nodes.count, 6)
    }

    func testCustomShaderInsideMacroUsesPackageShaderDirectory() throws {
        let shader = definition("custom-shader").makeNode(at: .zero)
        let source = try XCTUnwrap(shader.parameters["shaderSource"])
        var composition = CompositionFile.empty()
        composition.graph.nodes = [shader]
        composition = try MacroConverter.convert(
            selection: [shader.id],
            in: composition,
            name: "Shader Macro"
        ).composition

        let wrapper = try CompositionDocument(composition: composition).makePackageWrapper()
        let files = try XCTUnwrap(wrapper.fileWrappers)
        let shaderFiles = try XCTUnwrap(files["Shaders"]?.fileWrappers)
        let reopened = try CompositionDocument(packageWrapper: wrapper)
        let reopenedShader = try XCTUnwrap(
            reopened.composition.macroDefinitions.first?.graph.nodes.first
        )

        XCTAssertEqual(shaderFiles.count, 1)
        XCTAssertEqual(reopenedShader.parameters["shaderSource"], source)
    }

    func testImageMacroRendersThroughMetalPipeline() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let renderer = try MetalImageRenderer(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let target = try makePreviewTarget(device: device)
        let assetID = UUID()
        let filename = "macro-red.png"
        var image = definition("image-file").makeNode(at: .zero)
        image.parameters["assetID"] = .string(assetID.uuidString)
        let transform = definition("transform-2d").makeNode(at: .zero)
        let preview = definition("preview-output").makeNode(at: .zero)
        var composition = CompositionFile.empty()
        composition.graph = GraphRecord(
            nodes: [image, transform, preview],
            connections: [
                connect(image, "image", transform, "image"),
                connect(transform, "image", preview, "image"),
            ]
        )
        composition.assets = [
            AssetReference(
                id: assetID,
                filename: filename,
                originalFilename: filename,
                mediaType: AssetMediaKind.image.rawValue
            )
        ]
        composition = try MacroConverter.convert(
            selection: [transform.id],
            in: composition,
            name: "Image Transform"
        ).composition
        renderer.update(
            composition: composition,
            assets: [filename: try makeRedPNGData()],
            transport: PlaybackTransportState()
        )
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        XCTAssertTrue(
            renderer.encodeFrame(
                target: target,
                drawableSize: CGSize(width: 2, height: 2),
                commandBuffer: commandBuffer
            )
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: 16)
        target.getBytes(
            &bytes,
            bytesPerRow: 8,
            from: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0
        )
        XCTAssertGreaterThan(bytes[2], 245)
        XCTAssertEqual(bytes[3], 255)
    }

    private func makeControlFixture() -> (
        composition: CompositionFile, factor: NodeRecord, math: NodeRecord, sink: NodeRecord
    ) {
        var source = definition("number").makeNode(at: .zero)
        source.parameters["value"] = .number(6)
        var factor = definition("number").makeNode(at: CanvasPoint(x: 100, y: 0))
        factor.parameters["value"] = .number(7)
        var math = definition("math").makeNode(at: CanvasPoint(x: 220, y: 0))
        math.parameters["operation"] = .string("multiply")
        var sink = definition("map-range").makeNode(at: CanvasPoint(x: 360, y: 0))
        sink.parameters["clamp"] = .boolean(false)
        var composition = CompositionFile.empty()
        composition.graph = GraphRecord(
            nodes: [source, factor, math, sink],
            connections: [
                connect(source, "value", math, "a"),
                connect(factor, "value", math, "b"),
                connect(math, "result", sink, "value"),
            ]
        )
        return (composition, factor, math, sink)
    }

    private func makePreviewTarget(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func makeRedPNGData() throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 8,
                bitsPerPixel: 32
            )
        )
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in stride(from: 0, to: 16, by: 4) {
            pixels[index] = 255
            pixels[index + 1] = 0
            pixels[index + 2] = 0
            pixels[index + 3] = 255
        }
        return try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
    }

    private func definition(_ suffix: String) -> PatchDefinition {
        PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")!
    }

    private func connect(
        _ outputNode: NodeRecord,
        _ outputKey: String,
        _ inputNode: NodeRecord,
        _ inputKey: String
    ) -> ConnectionRecord {
        ConnectionRecord(
            outputNodeID: outputNode.id,
            outputPortID: outputNode.ports.first {
                $0.key == outputKey && $0.direction == .output
            }!.id,
            inputNodeID: inputNode.id,
            inputPortID: inputNode.ports.first {
                $0.key == inputKey && $0.direction == .input
            }!.id
        )
    }

    private func number(
        _ evaluation: GraphEvaluation,
        node: NodeRecord,
        key: String
    ) -> Double {
        guard
            case .number(let value) = evaluation.values[
                PortAddress(nodeID: node.id, portKey: key)
            ]
        else {
            XCTFail("Expected numeric output")
            return .nan
        }
        return value
    }
}
