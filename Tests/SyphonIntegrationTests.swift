import Metal
@preconcurrency import Syphon
import XCTest

@testable import Metaliquartz

@MainActor
final class SyphonIntegrationTests: XCTestCase {
    func testSyphonPatchDefinitionsUseTypedMetalImagePorts() throws {
        let input = try XCTUnwrap(definition("syphon-input"))
        let output = try XCTUnwrap(definition("syphon-output"))

        XCTAssertEqual(input.executorKind, .syphonInput)
        XCTAssertEqual(input.ports.map(\.direction), [.output])
        XCTAssertEqual(input.ports.map(\.dataType), [.image])
        XCTAssertEqual(output.executorKind, .syphonOutput)
        XCTAssertEqual(output.ports.map(\.direction), [.input])
        XCTAssertEqual(output.ports.map(\.dataType), [.image])
    }

    func testServerDescriptorRequiresUUIDAndBuildsStableDisplayName() throws {
        XCTAssertNil(SyphonServerDescriptor(description: [:]))
        let descriptor = try XCTUnwrap(
            SyphonServerDescriptor(
                description: [
                    SyphonServerDescriptionUUIDKey: "server-id",
                    SyphonServerDescriptionNameKey: "Main",
                    SyphonServerDescriptionAppNameKey: "Visuals",
                ]
            )
        )

        XCTAssertEqual(descriptor.id, "server-id")
        XCTAssertEqual(descriptor.displayName, "Visuals · Main")
    }

    func testTwoBridgesCompleteMetalLoopbackDisconnectAndReconnect() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let serverName = "Metaliquartz Tests \(UUID().uuidString)"
        let outputNode = makeOutputNode(name: serverName)
        let serverBridge = SyphonMetalBridge(device: device)
        serverBridge.update(composition: composition(nodes: [outputNode]))
        try publishRedFrame(
            bridge: serverBridge,
            node: outputNode,
            device: device,
            queue: queue
        )
        let firstDescriptor = try XCTUnwrap(serverBridge.outputDescriptor(nodeID: outputNode.id))
        XCTAssertTrue(
            waitUntil {
                SyphonDirectory.availableServers().contains { $0.id == firstDescriptor.id }
            }
        )

        let inputNode = makeInputNode(selection: firstDescriptor)
        let clientBridge = SyphonMetalBridge(device: device)
        clientBridge.update(composition: composition(nodes: [inputNode]))
        var received: (any MTLTexture)?
        XCTAssertTrue(
            waitUntil {
                received = clientBridge.inputTexture(for: inputNode)
                return received != nil
            }
        )
        XCTAssertEqual(received?.width, 2)
        XCTAssertEqual(received?.height, 2)
        XCTAssertEqual(received?.pixelFormat, .bgra8Unorm)

        serverBridge.update(composition: .empty())
        XCTAssertTrue(
            waitUntil {
                !SyphonDirectory.availableServers().contains { $0.id == firstDescriptor.id }
            }
        )
        XCTAssertNil(clientBridge.inputTexture(for: inputNode))
        XCTAssertNotNil(clientBridge.diagnostics[inputNode.id])

        let replacementNode = makeOutputNode(name: serverName)
        let replacementBridge = SyphonMetalBridge(device: device)
        replacementBridge.update(composition: composition(nodes: [replacementNode]))
        try publishRedFrame(
            bridge: replacementBridge,
            node: replacementNode,
            device: device,
            queue: queue
        )
        let replacementDescriptor = try XCTUnwrap(
            replacementBridge.outputDescriptor(nodeID: replacementNode.id)
        )
        XCTAssertNotEqual(replacementDescriptor.id, firstDescriptor.id)
        XCTAssertTrue(
            waitUntil {
                received = clientBridge.inputTexture(for: inputNode)
                return received != nil
            }
        )
        XCTAssertNil(clientBridge.diagnostics[inputNode.id])
    }

    private func publishRedFrame(
        bridge: SyphonMetalBridge,
        node: NodeRecord,
        device: any MTLDevice,
        queue: any MTLCommandQueue
    ) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pixels: [UInt8] = [
            0, 0, 255, 255, 0, 0, 255, 255,
            0, 0, 255, 255, 0, 0, 255, 255,
        ]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: 8
        )
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        bridge.publish(texture: texture, from: node, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
    }

    private func makeOutputNode(name: String) -> NodeRecord {
        var node = definition("syphon-output")!.makeNode(at: .zero)
        node.parameters["serverName"] = .string(name)
        return node
    }

    private func makeInputNode(selection: SyphonServerDescriptor) -> NodeRecord {
        var node = definition("syphon-input")!.makeNode(at: .zero)
        node.parameters["serverUUID"] = .string(selection.id)
        node.parameters["serverName"] = .string(selection.name)
        node.parameters["serverAppName"] = .string(selection.applicationName)
        return node
    }

    private func composition(nodes: [NodeRecord]) -> CompositionFile {
        var composition = CompositionFile.empty()
        composition.graph.nodes = nodes
        return composition
    }

    private func definition(_ suffix: String) -> PatchDefinition? {
        PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return condition()
    }
}
