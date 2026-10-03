import AppKit
import XCTest

@testable import Metaliquartz

final class QuartzComposerCatalogTests: XCTestCase {
    func testCatalogContainsAllReconstructedRowsAndIntentionalDuplicates() throws {
        XCTAssertEqual(QuartzComposerCatalog.oldEntries.count, 387)

        let mathEntries = QuartzComposerCatalog.oldEntries.filter { $0.name == "Math" }
        XCTAssertEqual(mathEntries.count, 2)
        XCTAssertEqual(Set(mathEntries.map(\.pathTitle)).count, 2)
        XCTAssertEqual(Set(mathEntries.compactMap(\.definitionID)).count, 1)

        let interpolation = try XCTUnwrap(
            QuartzComposerCatalog.oldEntries.first {
                $0.path == ["Animation"] && $0.name == "Interpolation"
            }
        )
        XCTAssertEqual(interpolation.status, .functional)
        XCTAssertEqual(
            interpolation.definitionID,
            "\(PatchRegistry.namespace).qc.interpolation"
        )
    }

    func testCatalogOnlyRowsAreInspectableButNotAddable() throws {
        let stopWatch = try XCTUnwrap(
            QuartzComposerCatalog.oldEntries.first { $0.name == "Stop Watch" }
        )

        XCTAssertEqual(stopWatch.status, .catalogOnly)
        XCTAssertFalse(stopWatch.isAddable)
        XCTAssertNil(QuartzComposerCatalog.addableEntry(id: stopWatch.id))
        XCTAssertEqual(QuartzComposerCatalog.entry(id: stopWatch.id), stopWatch)
    }

    func testRequestedMappingsUseDedicatedQuartzComposerDefinitions() {
        let requested = [
            "Interpolation", "Random", "Wave Generator (LFO)", "3D Transformation",
            "Iterator", "Lighting", "Replicate in Space", "Color Invert",
            "Linear Gradient", "Math", "Billboard", "Clear", "Cube", "Gradient",
            "Particle System", "Sphere", "Sprite",
        ]
        for name in requested {
            let entries = QuartzComposerCatalog.oldEntries.filter {
                $0.name == name && $0.status == .functional
            }
            XCTAssertFalse(entries.isEmpty, "Missing functional mapping for \(name)")
            XCTAssertTrue(entries.allSatisfy { $0.definitionID?.contains(".qc.") == true })
        }
        XCTAssertNotNil(PatchRegistry.definition(for: "\(PatchRegistry.namespace).lfo"))
        XCTAssertNotNil(PatchRegistry.definition(for: "\(PatchRegistry.namespace).math"))
        XCTAssertNotNil(PatchRegistry.definition(for: "\(PatchRegistry.namespace).sprite"))
    }
}

final class QuartzComposerPreferenceTests: XCTestCase {
    func testCategoryColorsPersistAndReset() throws {
        let suiteName = "QuartzComposerPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            CategoryColorPreferences.hex(for: "Animation", defaults: defaults),
            CategoryColorPreferences.defaultHex["Animation"]
        )
        CategoryColorPreferences.setColor(.systemRed, for: "Animation", defaults: defaults)
        XCTAssertNotEqual(
            CategoryColorPreferences.hex(for: "Animation", defaults: defaults),
            CategoryColorPreferences.defaultHex["Animation"]
        )
        CategoryColorPreferences.resetAll(defaults: defaults)
        XCTAssertEqual(
            CategoryColorPreferences.hex(for: "Animation", defaults: defaults),
            CategoryColorPreferences.defaultHex["Animation"]
        )
    }

    func testRotaryFaderMapsClampedTwoHundredSeventyDegreeArc() {
        let range = -10.0...30.0
        XCTAssertEqual(RotaryFaderMapping.angle(for: -10, in: range), -135)
        XCTAssertEqual(RotaryFaderMapping.angle(for: 30, in: range), 135)
        XCTAssertEqual(RotaryFaderMapping.value(for: 0, in: range), 10, accuracy: 0.000_001)
        XCTAssertEqual(RotaryFaderMapping.value(for: -999, in: range), -10)
        XCTAssertEqual(RotaryFaderMapping.value(for: 999, in: range), 30)
    }
}

final class QuartzComposerNestedGraphTests: XCTestCase {
    func testVersionOneMigratesWithoutChangingNodesOrConnections() throws {
        var composition = CompositionFile.empty(now: Date(timeIntervalSince1970: 100))
        let number = definition("number").makeNode(at: .zero)
        composition.graph = GraphRecord(nodes: [number], connections: [])
        let encoded = try CompositionCodec.encode(composition)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["version"] = 1
        var graph = try XCTUnwrap(object["graph"] as? [String: Any])
        graph.removeValue(forKey: "childGraphs")
        object["graph"] = graph

        let migrated = try CompositionCodec.decode(
            JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.graph.nodes, [number])
        XCTAssertTrue(migrated.graph.connections.isEmpty)
        XCTAssertTrue(migrated.graph.childGraphs.isEmpty)
    }

    func testStrictChildOwnershipValidation() {
        let iterator = definition("qc.iterator").makeNode(at: .zero)
        let valid = GraphRecord(
            nodes: [iterator],
            connections: [],
            childGraphs: [
                ChildGraphRecord(ownerNodeID: iterator.id, graph: .empty, editorState: .default)
            ]
        )
        XCTAssertTrue(GraphValidator.validate(valid).isEmpty)

        let orphanID = NodeID()
        let invalid = GraphRecord(
            nodes: [iterator],
            connections: [],
            childGraphs: [
                ChildGraphRecord(ownerNodeID: orphanID, graph: .empty, editorState: .default)
            ]
        )
        XCTAssertTrue(GraphValidator.validate(invalid).contains(.orphanChildGraph(orphanID)))
    }

    func testClipboardDuplicatesOwnedChildGraphsWithFreshIdentities() {
        let iterator = definition("qc.iterator").makeNode(at: .zero)
        let variable = definition("qc.iterator-variables").makeNode(at: .zero)
        let graph = GraphRecord(
            nodes: [iterator],
            connections: [],
            childGraphs: [
                ChildGraphRecord(
                    ownerNodeID: iterator.id,
                    graph: GraphRecord(nodes: [variable], connections: []),
                    editorState: .default
                )
            ]
        )

        let duplicate = GraphClipboardPayload.selection(
            from: graph, nodeIDs: Set([iterator.id])
        ).duplicated()

        XCTAssertEqual(duplicate.nodes.count, 1)
        XCTAssertEqual(duplicate.childGraphs.count, 1)
        XCTAssertEqual(duplicate.childGraphs[0].ownerNodeID, duplicate.nodes[0].id)
        XCTAssertNotEqual(duplicate.childGraphs[0].graph.nodes[0].id, variable.id)
    }

    private func definition(_ suffix: String) -> PatchDefinition {
        PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")!
    }
}

final class QuartzComposerRuntimeTests: XCTestCase {
    func testAllLFOShapesRemainFiniteAndPWMUsesRatio() {
        let shapes = ["sin", "cos", "triangle", "square", "saw-up", "saw-down", "pwm", "random"]
        for shape in shapes {
            let value = QCControlMath.lfo(
                time: 0.25,
                waveform: shape,
                period: 1,
                phase: 0,
                pwmRatio: 0.3,
                amplitude: 2,
                offset: 3
            )
            XCTAssertTrue(value.isFinite, "Non-finite output for \(shape)")
            XCTAssertGreaterThanOrEqual(value, 1)
            XCTAssertLessThanOrEqual(value, 5)
        }
        XCTAssertEqual(
            QCControlMath.lfo(
                time: 0.2, waveform: "pwm", period: 1, phase: 0,
                pwmRatio: 0.3, amplitude: 1, offset: 0
            ),
            1
        )
        XCTAssertEqual(
            QCControlMath.lfo(
                time: 0.4, waveform: "pwm", period: 1, phase: 0,
                pwmRatio: 0.3, amplitude: 1, offset: 0
            ),
            -1
        )
    }

    func testInterpolationRandomAndMathSemantics() throws {
        XCTAssertEqual(
            QCControlMath.interpolation(
                time: 0.5, start: 10, end: 20, duration: 1,
                repeatMode: "none", curve: "linear", tension: 0,
                controlPointsJSON: "[0,1]"
            ),
            15,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            QCControlMath.interpolation(
                time: 1.5, start: 0, end: 1, duration: 1,
                repeatMode: "mirror", curve: "linear", tension: 0,
                controlPointsJSON: "[0,1]"
            ),
            0.5,
            accuracy: 0.000_001
        )
        for index in 0..<100 {
            let value = QCControlMath.random(
                time: Double(index) / 10,
                minimum: -3,
                maximum: 7,
                rate: 10,
                seed: 42,
                smooth: index.isMultiple(of: 2)
            )
            XCTAssertGreaterThanOrEqual(value, -3)
            XCTAssertLessThanOrEqual(value, 7)
        }
        let math = try QCControlMath.math(
            inputs: ["initialValue": .number(2)],
            parameters: [
                "operations": .string(
                    "[{\"operation\":\"power\",\"value\":3},{\"operation\":\"modulo\",\"value\":5},{\"operation\":\"maximum\",\"value\":4}]"
                )
            ]
        )
        XCTAssertEqual(math, 4)
    }

    func testIteratorScopesAndReplicateEndpoints() throws {
        var iterator = definition("qc.iterator").makeNode(at: .zero)
        iterator.parameters["count"] = .number(3)
        let variables = definition("qc.iterator-variables").makeNode(at: .zero)
        let iteratorGraph = GraphRecord(
            nodes: [iterator],
            connections: [],
            childGraphs: [
                ChildGraphRecord(
                    ownerNodeID: iterator.id,
                    graph: GraphRecord(nodes: [variables], connections: []),
                    editorState: .default
                )
            ]
        )
        let iteratorEvaluation = GraphRuntime(
            schedule: try GraphCompiler.compile(iteratorGraph)
        ).evaluate(context: FrameContext(time: 0, deltaTime: 0, frameIndex: 0))
        let indices = iteratorEvaluation.scopedValues.values.compactMap { values -> Double? in
            guard
                case .number(let value) = values[
                    PortAddress(nodeID: variables.id, portKey: "index")
                ]
            else { return nil }
            return value
        }.sorted()
        XCTAssertEqual(indices, [0, 1, 2])

        var replicate = definition("qc.replicate-in-space").makeNode(at: .zero)
        replicate.parameters["copies"] = .number(2)
        let clear = definition("qc.clear").makeNode(at: .zero)
        let replicateGraph = GraphRecord(
            nodes: [replicate],
            connections: [],
            childGraphs: [
                ChildGraphRecord(
                    ownerNodeID: replicate.id,
                    graph: GraphRecord(nodes: [clear], connections: []),
                    editorState: .default
                )
            ]
        )
        let replicateEvaluation = GraphRuntime(
            schedule: try GraphCompiler.compile(replicateGraph)
        ).evaluate(context: FrameContext(time: 0, deltaTime: 0, frameIndex: 0))
        XCTAssertEqual(replicateEvaluation.consumers.count, 2)
        XCTAssertEqual(replicateEvaluation.consumers[0].scope.transforms.last?.progress, 0)
        XCTAssertEqual(replicateEvaluation.consumers[1].scope.transforms.last?.progress, 1)
    }

    func testConsumersSortByLayer() throws {
        var back = definition("qc.clear").makeNode(at: .zero)
        back.parameters["layer"] = .number(-1)
        var front = definition("qc.render-gradient").makeNode(at: .zero)
        front.parameters["layer"] = .number(20)
        let evaluation = GraphRuntime(
            schedule: try GraphCompiler.compile(
                GraphRecord(nodes: [front, back], connections: [])
            )
        ).evaluate(context: FrameContext(time: 0, deltaTime: 0, frameIndex: 0))

        XCTAssertEqual(evaluation.consumers.map(\.nodeID), [back.id, front.id])
    }

    private func definition(_ suffix: String) -> PatchDefinition {
        PatchRegistry.definition(for: "\(PatchRegistry.namespace).\(suffix)")!
    }
}

final class SyphonVendorModificationTests: XCTestCase {
    func testDeprecatedGlobalSurfacePropertyIsAbsent() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("Vendor/Syphon/SyphonServerBase.m"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("kIOSurfaceIsGlobal"))
        XCTAssertTrue(source.contains("IOSurfaceCreate"))
        XCTAssertTrue(source.contains("IOSurfaceGetID"))
    }
}
