import XCTest

@testable import Metaliquartz

final class GraphRuntimeTests: XCTestCase {
    func testCompilerProducesStableTopologicalOrderForFanOut() throws {
        let source = definition("number").makeNode(at: .zero)
        let first = definition("math").makeNode(at: .zero)
        let second = definition("map-range").makeNode(at: .zero)
        let graph = GraphRecord(
            nodes: [second, source, first],
            connections: [
                connect(source, "value", first, "a"),
                connect(source, "value", second, "value"),
            ]
        )

        let schedule = try GraphCompiler.compile(graph)

        XCTAssertEqual(schedule.nodes.map(\.nodeID), [source.id, second.id, first.id])
    }

    func testRuntimeEvaluatesConnectedMathGraphDeterministically() throws {
        var a = definition("number").makeNode(at: .zero)
        a.parameters["value"] = .number(6)
        var b = definition("number").makeNode(at: .zero)
        b.parameters["value"] = .number(7)
        var math = definition("math").makeNode(at: .zero)
        math.parameters["operation"] = .string("multiply")
        let graph = GraphRecord(
            nodes: [math, b, a],
            connections: [connect(a, "value", math, "a"), connect(b, "value", math, "b")]
        )
        let runtime = GraphRuntime(schedule: try GraphCompiler.compile(graph))

        let evaluation = runtime.evaluate(
            context: FrameContext(time: 10, deltaTime: 1.0 / 60.0, frameIndex: 600)
        )

        XCTAssertEqual(
            evaluation.values[PortAddress(nodeID: math.id, portKey: "result")], .number(42))
        XCTAssertTrue(evaluation.diagnostics.isEmpty)
    }

    func testTimeAndLFOUseOnlyFrameContext() throws {
        var lfo = definition("lfo").makeNode(at: .zero)
        lfo.parameters["waveform"] = .string("sine")
        lfo.parameters["frequency"] = .number(1)
        lfo.parameters["amplitude"] = .number(2)
        lfo.parameters["offset"] = .number(3)
        let runtime = GraphRuntime(
            schedule: try GraphCompiler.compile(GraphRecord(nodes: [lfo], connections: []))
        )

        let evaluation = runtime.evaluate(
            context: FrameContext(time: 0.25, deltaTime: 1.0 / 60.0, frameIndex: 15)
        )

        guard
            case .number(let value) = evaluation.values[
                PortAddress(nodeID: lfo.id, portKey: "value")
            ]
        else {
            return XCTFail("Expected numeric LFO output")
        }
        XCTAssertEqual(value, 5, accuracy: 0.000_001)
    }

    func testSmoothExecutorRetainsStateBetweenFrames() throws {
        let source = definition("time").makeNode(at: .zero)
        var smooth = definition("smooth").makeNode(at: .zero)
        smooth.parameters["response"] = .number(1)
        let graph = GraphRecord(
            nodes: [source, smooth],
            connections: [connect(source, "time", smooth, "value")]
        )
        let runtime = GraphRuntime(schedule: try GraphCompiler.compile(graph))
        let initialFrame = runtime.evaluate(
            context: FrameContext(time: 0, deltaTime: 0.1, frameIndex: 0)
        )
        let changedFrame = runtime.evaluate(
            context: FrameContext(time: 1, deltaTime: 0.1, frameIndex: 1)
        )
        let initialValue = number(initialFrame, node: smooth, key: "result")
        let changedValue = number(changedFrame, node: smooth, key: "result")

        XCTAssertEqual(initialValue, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(changedValue, 0)
        XCTAssertLessThan(changedValue, 1)
    }

    func testUnknownPatchIsDisabledAndReportedWithoutLosingPayload() throws {
        let unknown = NodeRecord(
            patchType: "third.party.future",
            name: "Future Patch",
            configuration: ["opaque": .object(["answer": .number(42)])]
        )
        let schedule = try GraphCompiler.compile(GraphRecord(nodes: [unknown], connections: []))

        XCTAssertTrue(schedule.snapshot.graph.nodes[0].isDisabled)
        XCTAssertEqual(schedule.snapshot.graph.nodes[0].configuration, unknown.configuration)
        let result = GraphRuntime(schedule: schedule).evaluate(
            context: FrameContext(time: 0, deltaTime: 0, frameIndex: 0)
        )
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics[0].severity, .warning)
    }

    func testCompilerRejectsInvalidGraph() {
        let input = PortRecord(
            id: PortID(),
            key: "input",
            name: "Input",
            direction: .input,
            dataType: .number
        )
        let node = NodeRecord(patchType: "test", name: "Invalid", ports: [input])
        let connection = ConnectionRecord(
            outputNodeID: node.id,
            outputPortID: input.id,
            inputNodeID: node.id,
            inputPortID: input.id
        )

        XCTAssertThrowsError(
            try GraphCompiler.compile(GraphRecord(nodes: [node], connections: [connection]))
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
            outputPortID: outputNode.ports.first { $0.key == outputKey }!.id,
            inputNodeID: inputNode.id,
            inputPortID: inputNode.ports.first { $0.key == inputKey }!.id
        )
    }

    private func number(_ evaluation: GraphEvaluation, node: NodeRecord, key: String) -> Double {
        guard
            case .number(let value) = evaluation.values[
                PortAddress(nodeID: node.id, portKey: key)
            ]
        else {
            XCTFail("Expected a numeric value")
            return .nan
        }
        return value
    }
}
