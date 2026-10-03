import Foundation

struct SampleComposition: Identifiable, Sendable {
    var id: String
    var title: String
    var summary: String
    var composition: CompositionFile

    var document: CompositionDocument {
        CompositionDocument(composition: composition)
    }
}

enum SampleCompositionLibrary {
    static var samples: [SampleComposition] {
        [controlModulation(), liveCameraFeedback()]
    }

    private static func controlModulation() -> SampleComposition {
        let time = node("time", x: 80, y: 100)
        let lfo = node("lfo", x: 80, y: 260)
        let math = node("math", x: 360, y: 170)
        var composition = CompositionFile.empty()
        composition.metadata.title = "Control Modulation"
        composition.graph = GraphRecord(
            nodes: [time, lfo, math],
            connections: [
                connection(from: time, output: "time", to: math, input: "a"),
                connection(from: lfo, output: "value", to: math, input: "b"),
            ]
        )
        composition.publishedParameters = [
            published("LFO Frequency", node: lfo, key: "frequency", range: 0...10),
            published("LFO Amplitude", node: lfo, key: "amplitude", range: 0...2),
        ]
        composition.controlMappings = composition.publishedParameters.map {
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: $0.id,
                source: .osc(address: OSCAddress.defaultAddress(for: $0.name)),
                minimum: $0.minimum ?? 0,
                maximum: $0.maximum ?? 1
            )
        }
        return SampleComposition(
            id: "control-modulation",
            title: composition.metadata.title,
            summary: "Time, LFO, Math, published controls, and ready-to-use OSC mappings.",
            composition: composition
        )
    }

    private static func liveCameraFeedback() -> SampleComposition {
        let camera = node("camera", x: 60, y: 110)
        let color = node("color-controls", x: 300, y: 110)
        let feedback = node("feedback", x: 300, y: 370)
        let blend = node("blend", x: 550, y: 190)
        let lines = node("line-grid", x: 800, y: 190)
        let preview = node("preview-output", x: 1_050, y: 100)
        let syphon = node("syphon-output", x: 1_050, y: 330)
        var composition = CompositionFile.empty()
        composition.metadata.title = "Live Camera Feedback"
        composition.graph = GraphRecord(
            nodes: [camera, color, feedback, blend, lines, preview, syphon],
            connections: [
                connection(from: camera, output: "image", to: color, input: "image"),
                connection(from: color, output: "image", to: blend, input: "background"),
                connection(from: feedback, output: "image", to: blend, input: "foreground"),
                connection(from: blend, output: "image", to: feedback, input: "image"),
                connection(from: blend, output: "image", to: lines, input: "image"),
                connection(from: lines, output: "image", to: preview, input: "image"),
                connection(from: lines, output: "image", to: syphon, input: "image"),
            ]
        )
        composition.editorState.viewport = CanvasViewport(
            origin: CanvasPoint(x: 20, y: 30),
            zoom: 0.8
        )
        composition.publishedParameters = [
            published("Feedback Mix", node: blend, key: "opacity", range: 0...1),
            published("Saturation", node: color, key: "saturation", range: 0...2),
            published("Line Displacement", node: lines, key: "displacement", range: 0...2),
        ]
        composition.controlMappings = composition.publishedParameters.map {
            ControlMappingRecord(
                id: UUID(),
                publishedParameterID: $0.id,
                source: .osc(address: OSCAddress.defaultAddress(for: $0.name)),
                minimum: $0.minimum ?? 0,
                maximum: $0.maximum ?? 1
            )
        }
        return SampleComposition(
            id: "live-camera-feedback",
            title: composition.metadata.title,
            summary: "Camera, color treatment, one-frame feedback, line-grid output, and Syphon.",
            composition: composition
        )
    }

    private static func node(_ suffix: String, x: Double, y: Double) -> NodeRecord {
        let identifier = "\(PatchRegistry.namespace).\(suffix)"
        guard let definition = PatchRegistry.definition(for: identifier) else {
            preconditionFailure("Missing built-in patch \(identifier)")
        }
        return definition.makeNode(at: CanvasPoint(x: x, y: y))
    }

    private static func connection(
        from outputNode: NodeRecord,
        output outputKey: String,
        to inputNode: NodeRecord,
        input inputKey: String
    ) -> ConnectionRecord {
        guard
            let outputPort = outputNode.ports.first(where: {
                $0.key == outputKey && $0.direction == .output
            }),
            let inputPort = inputNode.ports.first(where: {
                $0.key == inputKey && $0.direction == .input
            })
        else {
            preconditionFailure("A sample composition references a missing port")
        }
        return ConnectionRecord(
            outputNodeID: outputNode.id,
            outputPortID: outputPort.id,
            inputNodeID: inputNode.id,
            inputPortID: inputPort.id
        )
    }

    private static func published(
        _ name: String,
        node: NodeRecord,
        key: String,
        range: ClosedRange<Double>
    ) -> PublishedParameterRecord {
        PublishedParameterRecord(
            id: UUID(),
            name: name,
            nodeID: node.id,
            parameterKey: key,
            minimum: range.lowerBound,
            maximum: range.upperBound,
            smoothing: 0.08
        )
    }
}
