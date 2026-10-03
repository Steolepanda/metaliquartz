import Foundation

struct ImageRuntimeValue: Hashable, Sendable {
    let identifier: UUID

    init(identifier: UUID = UUID()) {
        self.identifier = identifier
    }
}

enum RuntimeValue: Hashable, Sendable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case color(red: Double, green: Double, blue: Double, alpha: Double)
    case image(ImageRuntimeValue)
    case event(sequence: UInt64)
}

extension QCColorMath.RGBA {
    /// Bridges the color arithmetic onto the graph's value type.
    var runtimeValue: RuntimeValue {
        .color(red: red, green: green, blue: blue, alpha: alpha)
    }
}

struct FrameContext: Hashable, Sendable {
    var time: Double
    var deltaTime: Double
    var frameIndex: UInt64
}

struct PortAddress: Hashable, Sendable {
    var nodeID: NodeID
    var portKey: String
}

struct GraphSnapshot: Hashable, Sendable {
    var graph: GraphRecord

    init(graph: GraphRecord) {
        var normalized = graph
        for index in normalized.nodes.indices
        where PatchRegistry.definition(for: normalized.nodes[index].patchType) == nil {
            normalized.nodes[index].isDisabled = true
        }
        self.graph = normalized
    }
}

struct ScheduledNode: Hashable, Sendable {
    var nodeID: NodeID
    var incomingConnections: [ConnectionRecord]
}

struct GraphSchedule: Hashable, Sendable {
    var snapshot: GraphSnapshot
    var nodes: [ScheduledNode]
}

enum GraphCompilationError: LocalizedError, Equatable {
    case invalidGraph([GraphValidationIssue])
    case invalidMacros([MacroValidationIssue])

    var errorDescription: String? {
        switch self {
        case .invalidGraph(let issues):
            issues.compactMap(\.errorDescription).joined(separator: "\n")
        case .invalidMacros(let issues):
            issues.compactMap(\.errorDescription).joined(separator: "\n")
        }
    }
}

enum GraphCompiler {
    static func compile(
        _ graph: GraphRecord,
        macros: [MacroDefinitionRecord] = []
    ) throws -> GraphSchedule {
        let issues = GraphValidator.validate(graph)
        guard issues.isEmpty else {
            throw GraphCompilationError.invalidGraph(issues)
        }

        let expanded: GraphRecord
        do {
            expanded = try MacroExpander.expand(graph: graph, macros: macros)
        } catch MacroExpansionError.invalidLibrary(let issues) {
            throw GraphCompilationError.invalidMacros(issues)
        }
        let expandedIssues = GraphValidator.validate(expanded)
        guard expandedIssues.isEmpty else {
            throw GraphCompilationError.invalidGraph(expandedIssues)
        }

        let snapshot = GraphSnapshot(graph: expanded)
        let nodes = snapshot.graph.nodes
        let positions = Dictionary(
            uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        var indegree = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var outgoing: [NodeID: [NodeID]] = [:]

        for connection in snapshot.graph.connections {
            guard
                let source = nodes.first(where: { $0.id == connection.outputNodeID }),
                !source.breaksFrameCycle
            else { continue }
            outgoing[connection.outputNodeID, default: []].append(connection.inputNodeID)
            indegree[connection.inputNodeID, default: 0] += 1
        }

        var ready = nodes.map(\.id).filter { indegree[$0] == 0 }
        var order: [NodeID] = []
        while !ready.isEmpty {
            let nodeID = ready.removeFirst()
            order.append(nodeID)
            for destination in outgoing[nodeID, default: []] {
                indegree[destination, default: 0] -= 1
                if indegree[destination] == 0 {
                    ready.append(destination)
                    ready.sort { positions[$0, default: 0] < positions[$1, default: 0] }
                }
            }
        }

        guard order.count == nodes.count else {
            throw GraphCompilationError.invalidGraph([.cycleDetected])
        }
        return GraphSchedule(
            snapshot: snapshot,
            nodes: order.map { nodeID in
                ScheduledNode(
                    nodeID: nodeID,
                    incomingConnections: snapshot.graph.connections.filter {
                        $0.inputNodeID == nodeID
                    }
                )
            }
        )
    }
}

enum PatchExecutionError: LocalizedError, Equatable {
    case invalidInput(String)
    case divisionByZero
    case degenerateRange
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let key): "The required input “\(key)” has no compatible value."
        case .divisionByZero: "Division by zero is undefined."
        case .degenerateRange: "The input range must have nonzero length."
        case .unavailable(let message): message
        }
    }
}

protocol PatchExecutor: AnyObject {
    func evaluate(
        context: FrameContext,
        inputs: [String: RuntimeValue],
        parameters: [String: ParameterValue]
    ) throws -> [String: RuntimeValue]
}

struct GraphRuntimeDiagnostic: Hashable, Sendable {
    enum Severity: String, Hashable, Sendable {
        case warning
        case error
    }

    var nodeID: NodeID
    var severity: Severity
    var message: String
}

struct IteratorRuntimeFrame: Hashable, Sendable {
    var count: Int
    var index: Int
    var position: Double
}

struct TransformRuntimeFrame: Hashable, Sendable {
    var progress: Double
    var parameters: [String: Double]
}

struct LightingRuntimeFrame: Hashable, Sendable {
    var ambient: RuntimeValue
    var shininess: Double
    var specularity: Double
    var lightCount: Int
    var shadowsEnabled: Bool
}

struct RuntimeEvaluationScope: Hashable, Sendable {
    var iteratorStack: [IteratorRuntimeFrame] = []
    var transforms: [TransformRuntimeFrame] = []
    var lighting: LightingRuntimeFrame?
    var blending = "over"
    var depthTesting = "read-write"
    var faceCulling = "none"
}

struct EvaluationPath: Hashable, Sendable {
    var components: [String] = ["root"]

    func appending(owner: NodeID, index: Int? = nil) -> EvaluationPath {
        var result = self
        result.components.append(owner.description)
        if let index { result.components.append(String(index)) }
        return result
    }
}

struct ConsumerExecution: Hashable, Sendable {
    var nodeID: NodeID
    var layer: Double
    var path: EvaluationPath
    var scope: RuntimeEvaluationScope
    var inputs: [String: RuntimeValue]
    var parameters: [String: ParameterValue]
}

struct GraphEvaluation: Sendable {
    var values: [PortAddress: RuntimeValue]
    var scopedValues: [EvaluationPath: [PortAddress: RuntimeValue]]
    var consumers: [ConsumerExecution]
    var diagnostics: [GraphRuntimeDiagnostic]
}

final class GraphRuntime {
    let schedule: GraphSchedule
    private struct ExecutionNodeKey: Hashable {
        var nodeID: NodeID
        var path: EvaluationPath
    }

    private var executors: [ExecutionNodeKey: any PatchExecutor] = [:]

    init(schedule: GraphSchedule) {
        self.schedule = schedule
    }

    func evaluate(context: FrameContext) -> GraphEvaluation {
        var values: [PortAddress: RuntimeValue] = [:]
        var scopedValues: [EvaluationPath: [PortAddress: RuntimeValue]] = [:]
        var consumers: [ConsumerExecution] = []
        var diagnostics: [GraphRuntimeDiagnostic] = []
        var evaluationBudget = 4_096
        evaluate(
            schedule: schedule,
            context: context,
            path: EvaluationPath(),
            scope: RuntimeEvaluationScope(),
            aggregateValues: &values,
            scopedValues: &scopedValues,
            consumers: &consumers,
            diagnostics: &diagnostics,
            evaluationBudget: &evaluationBudget
        )
        consumers.sort {
            if $0.layer == $1.layer {
                return $0.path.components.lexicographicallyPrecedes($1.path.components)
            }
            return $0.layer < $1.layer
        }
        return GraphEvaluation(
            values: values,
            scopedValues: scopedValues,
            consumers: consumers,
            diagnostics: diagnostics
        )
    }

    private func evaluate(
        schedule: GraphSchedule,
        context: FrameContext,
        path: EvaluationPath,
        scope: RuntimeEvaluationScope,
        aggregateValues: inout [PortAddress: RuntimeValue],
        scopedValues: inout [EvaluationPath: [PortAddress: RuntimeValue]],
        consumers: inout [ConsumerExecution],
        diagnostics: inout [GraphRuntimeDiagnostic],
        evaluationBudget: inout Int
    ) {
        var localValues: [PortAddress: RuntimeValue] = [:]
        let nodesByID = Dictionary(
            uniqueKeysWithValues: schedule.snapshot.graph.nodes.map { ($0.id, $0) }
        )

        for scheduledNode in schedule.nodes {
            guard let node = nodesByID[scheduledNode.nodeID] else { continue }
            guard !node.isDisabled else {
                diagnostics.append(
                    GraphRuntimeDiagnostic(
                        nodeID: node.id,
                        severity: .warning,
                        message:
                            "Patch type \(node.patchType) is unavailable; its data was preserved."
                    )
                )
                continue
            }
            var inputs: [String: RuntimeValue] = [:]
            for connection in scheduledNode.incomingConnections {
                guard
                    let sourceNode = nodesByID[connection.outputNodeID],
                    let outputPort = sourceNode.ports.first(where: {
                        $0.id == connection.outputPortID
                    }),
                    let inputPort = node.ports.first(where: { $0.id == connection.inputPortID }),
                    let value = localValues[
                        PortAddress(nodeID: sourceNode.id, portKey: outputPort.key)
                    ]
                else { continue }
                inputs[inputPort.key] = value
            }

            guard let definition = PatchRegistry.definition(for: node.patchType) else {
                continue
            }

            if definition.isContainer {
                evaluateContainer(
                    node: node,
                    definition: definition,
                    inputs: inputs,
                    parentSchedule: schedule,
                    context: context,
                    path: path,
                    scope: scope,
                    aggregateValues: &aggregateValues,
                    scopedValues: &scopedValues,
                    consumers: &consumers,
                    diagnostics: &diagnostics,
                    evaluationBudget: &evaluationBudget
                )
                continue
            }

            if definition.executorKind == .iteratorVariables {
                guard let frame = scope.iteratorStack.last else {
                    diagnostics.append(
                        GraphRuntimeDiagnostic(
                            nodeID: node.id,
                            severity: .error,
                            message: "Iterator Variables is outside an Iterator child graph."
                        )
                    )
                    continue
                }
                let outputs: [String: RuntimeValue] = [
                    "count": .number(Double(frame.count)),
                    "index": .number(Double(frame.index)),
                    "position": .number(frame.position),
                ]
                store(
                    outputs: outputs,
                    nodeID: node.id,
                    path: path,
                    localValues: &localValues,
                    aggregateValues: &aggregateValues
                )
                continue
            }

            let key = ExecutionNodeKey(nodeID: node.id, path: path)
            let executor: any PatchExecutor
            if let existing = executors[key] {
                executor = existing
            } else {
                let created = PatchExecutorFactory.make(definition.executorKind)
                executors[key] = created
                executor = created
            }

            do {
                let outputs = try executor.evaluate(
                    context: context,
                    inputs: inputs,
                    parameters: node.parameters
                )
                store(
                    outputs: outputs,
                    nodeID: node.id,
                    path: path,
                    localValues: &localValues,
                    aggregateValues: &aggregateValues
                )
                if definition.isConsumer,
                    inputs.boolean(
                        "enable", default: node.parameters.boolean("enable", default: true))
                {
                    var consumerScope = scope
                    consumerScope.blending = inputs.string(
                        "blending",
                        default: node.parameters.string("blending", default: "over")
                    )
                    consumerScope.depthTesting = inputs.string(
                        "depthTesting",
                        default: node.parameters.string("depthTesting", default: "read-write")
                    )
                    consumerScope.faceCulling = inputs.string(
                        "faceCulling",
                        default: node.parameters.string("faceCulling", default: "none")
                    )
                    consumers.append(
                        ConsumerExecution(
                            nodeID: node.id,
                            layer: inputs.number(
                                "layer", default: node.parameters.number("layer")
                            ),
                            path: path,
                            scope: consumerScope,
                            inputs: inputs,
                            parameters: node.parameters
                        )
                    )
                }
            } catch {
                diagnostics.append(
                    GraphRuntimeDiagnostic(
                        nodeID: node.id,
                        severity: .error,
                        message: error.localizedDescription
                    )
                )
            }
        }
        scopedValues[path, default: [:]].merge(localValues) { _, new in new }
    }

    private func evaluateContainer(
        node: NodeRecord,
        definition: PatchDefinition,
        inputs: [String: RuntimeValue],
        parentSchedule: GraphSchedule,
        context: FrameContext,
        path: EvaluationPath,
        scope: RuntimeEvaluationScope,
        aggregateValues: inout [PortAddress: RuntimeValue],
        scopedValues: inout [EvaluationPath: [PortAddress: RuntimeValue]],
        consumers: inout [ConsumerExecution],
        diagnostics: inout [GraphRuntimeDiagnostic],
        evaluationBudget: inout Int
    ) {
        guard
            let child = parentSchedule.snapshot.graph.childGraphs.first(where: {
                $0.ownerNodeID == node.id
            })
        else {
            diagnostics.append(
                GraphRuntimeDiagnostic(
                    nodeID: node.id,
                    severity: .error,
                    message: "Container has no owned child graph."
                )
            )
            return
        }
        let childSchedule: GraphSchedule
        do {
            childSchedule = try GraphCompiler.compile(child.graph)
        } catch {
            diagnostics.append(
                GraphRuntimeDiagnostic(
                    nodeID: node.id,
                    severity: .error,
                    message: error.localizedDescription
                )
            )
            return
        }

        switch definition.executorKind {
        case .iterator:
            let requested = max(
                0,
                Int(inputs.number("count", default: node.parameters.number("count", default: 1)))
            )
            let count = min(requested, evaluationBudget)
            if requested > count {
                appendCapDiagnostic(node: node, diagnostics: &diagnostics)
            }
            for index in 0..<count {
                evaluationBudget -= 1
                var childScope = scope
                childScope.iteratorStack.append(
                    IteratorRuntimeFrame(
                        count: count,
                        index: index,
                        position: count <= 1 ? 0 : Double(index) / Double(count - 1)
                    )
                )
                evaluate(
                    schedule: childSchedule,
                    context: context,
                    path: path.appending(owner: node.id, index: index),
                    scope: childScope,
                    aggregateValues: &aggregateValues,
                    scopedValues: &scopedValues,
                    consumers: &consumers,
                    diagnostics: &diagnostics,
                    evaluationBudget: &evaluationBudget
                )
            }
        case .replicateInSpace:
            let requested = max(
                0,
                Int(inputs.number("copies", default: node.parameters.number("copies", default: 1)))
            )
            let count = min(requested, evaluationBudget)
            if requested > count {
                appendCapDiagnostic(node: node, diagnostics: &diagnostics)
            }
            for index in 0..<count {
                evaluationBudget -= 1
                let raw = count <= 1 ? 0 : Double(index) / Double(count - 1)
                let progress = QCControlMath.curveProgress(
                    raw,
                    curve: node.parameters.string("interpolation", default: "linear")
                )
                var childScope = scope
                childScope.transforms.append(
                    TransformRuntimeFrame(
                        progress: progress,
                        parameters: node.parameters.numericValues(prefix: "final")
                    )
                )
                evaluate(
                    schedule: childSchedule,
                    context: context,
                    path: path.appending(owner: node.id, index: index),
                    scope: childScope,
                    aggregateValues: &aggregateValues,
                    scopedValues: &scopedValues,
                    consumers: &consumers,
                    diagnostics: &diagnostics,
                    evaluationBudget: &evaluationBudget
                )
            }
        case .transformation3D:
            var childScope = scope
            childScope.transforms.append(
                TransformRuntimeFrame(
                    progress: 1,
                    parameters: node.parameters.numericValues(prefix: nil)
                )
            )
            evaluate(
                schedule: childSchedule,
                context: context,
                path: path.appending(owner: node.id),
                scope: childScope,
                aggregateValues: &aggregateValues,
                scopedValues: &scopedValues,
                consumers: &consumers,
                diagnostics: &diagnostics,
                evaluationBudget: &evaluationBudget
            )
        case .lighting:
            var childScope = scope
            childScope.lighting = LightingRuntimeFrame(
                ambient: node.parameters.runtimeColor("ambient"),
                shininess: node.parameters.number("shininess", default: 32),
                specularity: node.parameters.number("specularity", default: 0.5),
                lightCount: min(8, max(0, Int(node.parameters.number("lightCount", default: 1)))),
                shadowsEnabled: node.parameters.boolean("shadows")
            )
            evaluate(
                schedule: childSchedule,
                context: context,
                path: path.appending(owner: node.id),
                scope: childScope,
                aggregateValues: &aggregateValues,
                scopedValues: &scopedValues,
                consumers: &consumers,
                diagnostics: &diagnostics,
                evaluationBudget: &evaluationBudget
            )
        default:
            break
        }
    }

    private func store(
        outputs: [String: RuntimeValue],
        nodeID: NodeID,
        path: EvaluationPath,
        localValues: inout [PortAddress: RuntimeValue],
        aggregateValues: inout [PortAddress: RuntimeValue]
    ) {
        for (key, value) in outputs {
            let address = PortAddress(nodeID: nodeID, portKey: key)
            localValues[address] = value
            aggregateValues[address] = value
        }
    }

    private func appendCapDiagnostic(
        node: NodeRecord,
        diagnostics: inout [GraphRuntimeDiagnostic]
    ) {
        diagnostics.append(
            GraphRuntimeDiagnostic(
                nodeID: node.id,
                severity: .warning,
                message: "Iterator/replicate evaluation was capped at 4,096 executions."
            )
        )
    }
}

private enum PatchExecutorFactory {
    static func make(_ kind: PatchExecutorKind) -> any PatchExecutor {
        ControlPatchExecutor(kind: kind)
    }
}

private final class ControlPatchExecutor: PatchExecutor {
    private let kind: PatchExecutorKind
    private var smoothedValue: Double?

    init(kind: PatchExecutorKind) {
        self.kind = kind
    }

    func evaluate(
        context: FrameContext,
        inputs: [String: RuntimeValue],
        parameters: [String: ParameterValue]
    ) throws -> [String: RuntimeValue] {
        switch kind {
        case .number:
            return ["value": .number(parameters.number("value"))]
        case .boolean:
            return ["value": .boolean(parameters.boolean("value"))]
        case .color:
            return ["color": parameters.runtimeColor("color")]
        case .time:
            let value =
                context.time * parameters.number("speed", default: 1)
                + parameters.number("offset")
            return ["time": .number(value)]
        case .lfo:
            return ["value": .number(lfo(context: context, parameters: parameters))]
        case .math:
            return ["result": .number(try math(inputs: inputs, parameters: parameters))]
        case .qcInterpolation:
            let start = inputs.number("startValue", default: parameters.number("startValue"))
            let end = inputs.number("endValue", default: parameters.number("endValue", default: 1))
            return [
                "value": .number(
                    QCControlMath.interpolation(
                        time: context.time,
                        start: start,
                        end: end,
                        duration: parameters.number("duration", default: 1),
                        repeatMode: parameters.string("repeatMode", default: "none"),
                        curve: parameters.string("curve", default: "linear"),
                        tension: parameters.number("tension"),
                        controlPointsJSON: parameters.string(
                            "controlPoints", default: "[0,0.25,0.5,0.75,1]"
                        )
                    )
                )
            ]
        case .qcRandom:
            let minimum = inputs.number("minimum", default: parameters.number("minimum"))
            let maximum = inputs.number(
                "maximum", default: parameters.number("maximum", default: 1))
            return [
                "value": .number(
                    QCControlMath.random(
                        time: context.time,
                        minimum: minimum,
                        maximum: maximum,
                        rate: parameters.number("rate", default: 1),
                        seed: UInt64(max(0, parameters.number("seed"))),
                        smooth: parameters.string("mode", default: "discontinuous") == "perlin"
                    )
                )
            ]
        case .qcLFO:
            return [
                "value": .number(
                    QCControlMath.lfo(
                        time: context.time,
                        waveform: parameters.string("waveform", default: "sin"),
                        period: parameters.number("period", default: 1),
                        phase: parameters.number("phase"),
                        pwmRatio: parameters.number("pwmRatio", default: 0.5),
                        amplitude: parameters.number("amplitude", default: 1),
                        offset: parameters.number("offset")
                    )
                )
            ]
        case .qcMath:
            return [
                "result": .number(try QCControlMath.math(inputs: inputs, parameters: parameters))
            ]
        case .mapRange:
            return ["result": .number(try mapRange(inputs: inputs, parameters: parameters))]
        case .smooth:
            let input = try inputs.requiredNumber("value")
            let response = max(0.001, parameters.number("response", default: 0.2))
            let alpha = 1 - exp(-max(0, context.deltaTime) / response)
            let result = smoothedValue.map { $0 + (input - $0) * alpha } ?? input
            smoothedValue = result
            return ["result": .number(result)]
        case .switchNumber:
            let key = inputs.boolean("condition") ? "trueValue" : "falseValue"
            return ["result": .number(inputs.number(key))]
        case .passthroughImage, .transformImage, .colorControls, .blur, .glow, .customShader,
            .sprite, .meshDisplacement, .pointGrid, .lineGrid, .feedback, .colorInvert:
            guard let image = inputs["image"] else {
                throw PatchExecutionError.invalidInput("image")
            }
            return ["image": image]
        case .blend:
            guard let image = inputs["foreground"] ?? inputs["background"] else {
                throw PatchExecutionError.invalidInput("foreground")
            }
            return ["image": image]
        case .displace:
            guard let image = inputs["image"] else {
                throw PatchExecutionError.invalidInput("image")
            }
            return ["image": image]
        case .previewOutput, .syphonOutput, .clear, .renderGradient, .billboard, .qcSprite,
            .cube, .sphere, .particleSystem, .iterator, .transformation3D, .replicateInSpace,
            .lighting:
            return [:]
        case .iteratorVariables:
            throw PatchExecutionError.unavailable(
                "Iterator Variables must be evaluated inside an Iterator child graph."
            )
        case .qcColorFromComponentsRGB:
            return [
                "outputColor": .color(
                    red: qcComponent(inputs, parameters, "input1"),
                    green: qcComponent(inputs, parameters, "input2"),
                    blue: qcComponent(inputs, parameters, "input3"),
                    alpha: qcComponent(inputs, parameters, "inputAlpha")
                )
            ]
        case .qcColorFromComponentsHSL:
            let color = QCColorMath.rgba(
                from: QCColorMath.HSL(
                    hue: qcComponent(inputs, parameters, "input1"),
                    saturation: qcComponent(inputs, parameters, "input2"),
                    luminosity: qcComponent(inputs, parameters, "input3")
                ),
                alpha: qcComponent(inputs, parameters, "inputAlpha")
            )
            return ["outputColor": color.runtimeValue]
        case .qcColorToComponentsRGB:
            let color = try qcColor(inputs, parameters)
            return [
                "output1": .number(color.red),
                "output2": .number(color.green),
                "output3": .number(color.blue),
                "outputAlpha": .number(color.alpha),
            ]
        case .qcColorToComponentsHSL:
            let color = try qcColor(inputs, parameters)
            let hsl = QCColorMath.hsl(from: color)
            return [
                "output1": .number(hsl.hue),
                "output2": .number(hsl.saturation),
                "output3": .number(hsl.luminosity),
                "outputAlpha": .number(color.alpha),
            ]
        case .qcColorMixer:
            let mixed = QCColorMath.mix(
                try qcColor(inputs, parameters, key: "inputColor1"),
                try qcColor(inputs, parameters, key: "inputColor2"),
                amount: qcComponent(inputs, parameters, "inputMix", default: 0.5),
                interpolation: parameters.string("inputInterpolation", default: "Linear")
            )
            return ["outputColor": mixed.runtimeValue]
        case .qcColorTransform:
            let transformed = QCColorMath.transform(
                try qcColor(inputs, parameters),
                hueRotation: qcComponent(inputs, parameters, "inputHue"),
                saturation: qcComponent(inputs, parameters, "inputSaturation", default: 1),
                luminosity: qcComponent(inputs, parameters, "inputLuminosity", default: 1),
                alpha: qcComponent(inputs, parameters, "inputAlpha", default: 1)
            )
            return ["outputColor": transformed.runtimeValue]
        case .linearGradient:
            return ["image": .image(ImageRuntimeValue())]
        case .unavailableImage, .movieImage, .cameraImage, .syphonInput:
            throw PatchExecutionError.unavailable(
                "Image loading is not active until the image-pipeline milestone."
            )
        }
    }

    // MARK: - Quartz Composer color helpers
    //
    // The generated Color patches use Quartz Composer's own port keys. A component input
    // prefers a connection, then the node's own parameter, then its default.

    private func qcComponent(
        _ inputs: [String: RuntimeValue],
        _ parameters: [String: ParameterValue],
        _ key: String,
        default fallback: Double = 0
    ) -> Double {
        inputs.number(key, default: parameters.number(key, default: fallback))
    }

    private func qcColor(
        _ inputs: [String: RuntimeValue],
        _ parameters: [String: ParameterValue],
        key: String = "inputColor"
    ) throws -> QCColorMath.RGBA {
        if case .color(let red, let green, let blue, let alpha)? = inputs[key] {
            return QCColorMath.RGBA(red: red, green: green, blue: blue, alpha: alpha)
        }
        if case .color(let red, let green, let blue, let alpha)? = parameters[key] {
            return QCColorMath.RGBA(red: red, green: green, blue: blue, alpha: alpha)
        }
        throw PatchExecutionError.invalidInput(key)
    }

    private func lfo(
        context: FrameContext,
        parameters: [String: ParameterValue]
    ) -> Double {
        let phase = context.time * parameters.number("frequency", default: 1)
        let fraction = phase - floor(phase)
        let signal: Double
        switch parameters.string("waveform", default: "sine") {
        case "triangle": signal = 1 - 4 * abs(round(phase) - phase)
        case "saw": signal = 2 * fraction - 1
        case "square": signal = fraction < 0.5 ? 1 : -1
        default: signal = sin(phase * 2 * .pi)
        }
        return signal * parameters.number("amplitude", default: 1)
            + parameters.number("offset")
    }

    private func math(
        inputs: [String: RuntimeValue],
        parameters: [String: ParameterValue]
    ) throws -> Double {
        let a = inputs.number("a")
        let b = inputs.number("b")
        switch parameters.string("operation", default: "add") {
        case "subtract": return a - b
        case "multiply": return a * b
        case "divide":
            guard abs(b) > .ulpOfOne else { throw PatchExecutionError.divisionByZero }
            return a / b
        case "minimum": return min(a, b)
        case "maximum": return max(a, b)
        default: return a + b
        }
    }

    private func mapRange(
        inputs: [String: RuntimeValue],
        parameters: [String: ParameterValue]
    ) throws -> Double {
        let inputMinimum = parameters.number("inputMinimum")
        let inputMaximum = parameters.number("inputMaximum", default: 1)
        guard inputMinimum != inputMaximum else { throw PatchExecutionError.degenerateRange }
        var progress = (inputs.number("value") - inputMinimum) / (inputMaximum - inputMinimum)
        if parameters.boolean("clamp", default: true) {
            progress = min(1, max(0, progress))
        }
        let outputMinimum = parameters.number("outputMinimum")
        let outputMaximum = parameters.number("outputMaximum", default: 1)
        return outputMinimum + progress * (outputMaximum - outputMinimum)
    }
}

enum QCControlMath {
    private struct Operation: Decodable {
        var operation: String
        var value: Double
    }

    static func interpolation(
        time: Double,
        start: Double,
        end: Double,
        duration: Double,
        repeatMode: String,
        curve: String,
        tension: Double,
        controlPointsJSON: String
    ) -> Double {
        let safeDuration = max(0.001, duration)
        let raw = max(0, time) / safeDuration
        let progress: Double
        switch repeatMode {
        case "loop":
            progress = raw - floor(raw)
        case "mirror":
            let cycle = raw - floor(raw / 2) * 2
            progress = cycle <= 1 ? cycle : 2 - cycle
        default:
            progress = min(1, raw)
        }
        let shaped = curveValue(
            progress,
            curve: curve,
            tension: tension,
            controlPointsJSON: controlPointsJSON
        )
        return start + (end - start) * shaped
    }

    static func curveProgress(_ progress: Double, curve: String) -> Double {
        curveValue(
            progress,
            curve: curve,
            tension: 0,
            controlPointsJSON: "[0,1]"
        )
    }

    static func lfo(
        time: Double,
        waveform: String,
        period: Double,
        phase: Double,
        pwmRatio: Double,
        amplitude: Double,
        offset: Double
    ) -> Double {
        let cycle = time / max(0.001, period) + phase
        let fraction = cycle - floor(cycle)
        let signal: Double
        switch waveform {
        case "cos": signal = cos(cycle * 2 * .pi)
        case "triangle": signal = 1 - 4 * abs(fraction - 0.5)
        case "square": signal = fraction < 0.5 ? 1 : -1
        case "saw-up": signal = fraction * 2 - 1
        case "saw-down": signal = 1 - fraction * 2
        case "pwm": signal = fraction < min(1, max(0, pwmRatio)) ? 1 : -1
        case "random": signal = unitRandom(index: Int64(floor(cycle)), seed: 0) * 2 - 1
        default: signal = sin(cycle * 2 * .pi)
        }
        return signal * amplitude + offset
    }

    static func random(
        time: Double,
        minimum: Double,
        maximum: Double,
        rate: Double,
        seed: UInt64,
        smooth: Bool
    ) -> Double {
        let position = max(0, time) * max(0, rate)
        let index = Int64(floor(position))
        var unit = unitRandom(index: index, seed: seed)
        if smooth {
            let fraction = position - floor(position)
            let eased = fraction * fraction * (3 - 2 * fraction)
            let next = unitRandom(index: index + 1, seed: seed)
            unit += (next - unit) * eased
        }
        return minimum + (maximum - minimum) * unit
    }

    static func math(
        inputs: [String: RuntimeValue],
        parameters: [String: ParameterValue]
    ) throws -> Double {
        var value = inputs.number(
            "initialValue", default: parameters.number("initialValue")
        )
        let json = parameters.string(
            "operations", default: "[{\"operation\":\"add\",\"value\":0}]"
        )
        let data = Data(json.utf8)
        let operations = (try? JSONDecoder().decode([Operation].self, from: data)) ?? []
        for (index, operation) in operations.prefix(64).enumerated() {
            let operand =
                index == 0
                ? inputs.number("operand", default: operation.value) : operation.value
            switch operation.operation {
            case "subtract": value -= operand
            case "multiply": value *= operand
            case "divide":
                guard abs(operand) > .ulpOfOne else {
                    throw PatchExecutionError.divisionByZero
                }
                value /= operand
            case "modulo":
                guard abs(operand) > .ulpOfOne else {
                    throw PatchExecutionError.divisionByZero
                }
                value.formTruncatingRemainder(dividingBy: operand)
            case "power": value = pow(value, operand)
            case "minimum": value = min(value, operand)
            case "maximum": value = max(value, operand)
            default: value += operand
            }
        }
        return value
    }

    private static func curveValue(
        _ progress: Double,
        curve: String,
        tension: Double,
        controlPointsJSON: String
    ) -> Double {
        let x = min(1, max(0, progress))
        switch curve {
        case "quadratic-in": return x * x
        case "quadratic-out": return 1 - (1 - x) * (1 - x)
        case "quadratic-in-out":
            return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        case "cubic-in": return x * x * x
        case "cubic-out": return 1 - pow(1 - x, 3)
        case "cubic-in-out":
            return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case "exponential-in": return x == 0 ? 0 : pow(2, 10 * x - 10)
        case "exponential-out": return x == 1 ? 1 : 1 - pow(2, -10 * x)
        case "exponential-in-out":
            if x == 0 || x == 1 { return x }
            return x < 0.5
                ? pow(2, 20 * x - 10) / 2
                : (2 - pow(2, -20 * x + 10)) / 2
        case "sinusoidal-in": return 1 - cos(x * .pi / 2)
        case "sinusoidal-out": return sin(x * .pi / 2)
        case "sinusoidal-in-out": return -(cos(.pi * x) - 1) / 2
        case "spline":
            let data = Data(controlPointsJSON.utf8)
            let points = ((try? JSONDecoder().decode([Double].self, from: data)) ?? [0, 1])
                .prefix(16)
            return spline(x, points: Array(points), tension: min(1, max(-1, tension)))
        default: return x
        }
    }

    private static func spline(_ x: Double, points: [Double], tension: Double) -> Double {
        guard points.count > 1 else { return x }
        let scaled = x * Double(points.count - 1)
        let segment = min(points.count - 2, max(0, Int(floor(scaled))))
        let t = scaled - Double(segment)
        let p0 = points[max(0, segment - 1)]
        let p1 = points[segment]
        let p2 = points[segment + 1]
        let p3 = points[min(points.count - 1, segment + 2)]
        let tangentScale = (1 - tension) / 2
        let m1 = (p2 - p0) * tangentScale
        let m2 = (p3 - p1) * tangentScale
        let t2 = t * t
        let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p1
            + (t3 - 2 * t2 + t) * m1
            + (-2 * t3 + 3 * t2) * p2
            + (t3 - t2) * m2
    }

    private static func unitRandom(index: Int64, seed: UInt64) -> Double {
        var value = UInt64(bitPattern: index) &+ seed &* 0x9E37_79B9_7F4A_7C15
        value ^= value >> 30
        value &*= 0xBF58_476D_1CE4_E5B9
        value ^= value >> 27
        value &*= 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}

extension Dictionary where Key == String, Value == RuntimeValue {
    fileprivate func number(_ key: String, default fallback: Double = 0) -> Double {
        guard case .number(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func requiredNumber(_ key: String) throws -> Double {
        guard case .number(let value) = self[key] else {
            throw PatchExecutionError.invalidInput(key)
        }
        return value
    }

    fileprivate func boolean(_ key: String, default fallback: Bool = false) -> Bool {
        guard case .boolean(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func string(_ key: String, default fallback: String = "") -> String {
        guard case .string(let value) = self[key] else { return fallback }
        return value
    }
}

extension Dictionary where Key == String, Value == ParameterValue {
    fileprivate func number(_ key: String, default fallback: Double = 0) -> Double {
        guard case .number(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func boolean(_ key: String, default fallback: Bool = false) -> Bool {
        guard case .boolean(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func string(_ key: String, default fallback: String = "") -> String {
        guard case .string(let value) = self[key] else { return fallback }
        return value
    }

    fileprivate func runtimeColor(_ key: String) -> RuntimeValue {
        guard case .color(let red, let green, let blue, let alpha) = self[key] else {
            return .color(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return .color(red: red, green: green, blue: blue, alpha: alpha)
    }

    fileprivate func numericValues(prefix: String?) -> [String: Double] {
        reduce(into: [:]) { result, pair in
            guard case .number(let value) = pair.value else { return }
            if let prefix, !pair.key.hasPrefix(prefix) { return }
            result[pair.key] = value
        }
    }
}
