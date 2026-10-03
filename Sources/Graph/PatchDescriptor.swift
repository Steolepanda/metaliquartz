import Foundation

enum PatchCategory: String, CaseIterable, Sendable {
    case control = "Control"
    case input = "Input"
    case processing = "Processing"
    case rendering = "Rendering"
}

struct PortTemplate: Hashable, Sendable {
    let key: String
    let name: String
    let direction: PortDirection
    let dataType: PortDataType
}

enum ParameterSchema: Hashable, Sendable {
    case number(key: String, name: String, defaultValue: Double, range: ClosedRange<Double>)
    case boolean(key: String, name: String, defaultValue: Bool)
    case string(key: String, name: String, defaultValue: String)
    case choice(key: String, name: String, defaultValue: String, choices: [String])
    case color(key: String, name: String, defaultValue: ParameterValue)
    case asset(key: String, name: String, mediaKind: AssetMediaKind)
    case code(key: String, name: String, defaultValue: String)

    var key: String {
        switch self {
        case .number(let key, _, _, _),
            .boolean(let key, _, _),
            .string(let key, _, _),
            .choice(let key, _, _, _),
            .color(let key, _, _),
            .asset(let key, _, _),
            .code(let key, _, _):
            key
        }
    }

    var name: String {
        switch self {
        case .number(_, let name, _, _),
            .boolean(_, let name, _),
            .string(_, let name, _),
            .choice(_, let name, _, _),
            .color(_, let name, _),
            .asset(_, let name, _),
            .code(_, let name, _):
            name
        }
    }

    var defaultValue: ParameterValue {
        switch self {
        case .number(_, _, let value, _): .number(value)
        case .boolean(_, _, let value): .boolean(value)
        case .string(_, _, let value), .choice(_, _, let value, _): .string(value)
        case .color(_, _, let value): value
        case .asset: .string("")
        case .code(_, _, let value): .string(value)
        }
    }
}

struct ShaderParameterDeclaration: Codable, Hashable, Sendable, Identifiable {
    var key: String
    var name: String
    var defaultValue: Double
    var minimum: Double
    var maximum: Double

    var id: String { key }
}

enum CustomShaderSource {
    static let metadataPrefix = "// mq-parameters:"
    static let defaultSource = """
        #include <metal_stdlib>
        using namespace metal;

        // mq-parameters: [{"key":"amount","name":"Amount","defaultValue":0.5,"minimum":0,"maximum":1}]

        struct MQVertex {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        struct MQFrameUniforms {
            float time;
            float deltaTime;
            float2 resolution;
            uint frameIndex;
        };

        fragment half4 mqFragment(
            MQVertex input [[stage_in]],
            texture2d<half> source [[texture(0)]],
            sampler sourceSampler [[sampler(0)]],
            constant MQFrameUniforms &frame [[buffer(0)]],
            constant float4 &parameters [[buffer(1)]]) {
            half4 color = source.sample(sourceSampler, input.textureCoordinate);
            float pulse = 0.5 + 0.5 * sin(frame.time * 2.0);
            return half4(mix(color.rgb, color.bgr, half(parameters.x * pulse)), color.a);
        }
        """

    static func parameterDeclarations(in source: String) -> [ShaderParameterDeclaration] {
        guard
            let line = source.split(separator: "\n").first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(metadataPrefix)
            })
        else { return [] }
        let text = line.trimmingCharacters(in: .whitespaces)
            .dropFirst(metadataPrefix.count)
            .trimmingCharacters(in: .whitespaces)
        guard let data = text.data(using: .utf8) else { return [] }
        return Array(
            ((try? JSONDecoder().decode([ShaderParameterDeclaration].self, from: data)) ?? [])
                .prefix(4)
        )
    }
}

enum AssetMediaKind: String, Hashable, Sendable {
    case image
    case movie
}

enum PatchExecutorKind: String, Hashable, Sendable {
    case number
    case boolean
    case color
    case time
    case lfo
    case math
    case mapRange
    case smooth
    case switchNumber
    case unavailableImage
    case movieImage
    case cameraImage
    case passthroughImage
    case transformImage
    case colorControls
    case blend
    case blur
    case glow
    case displace
    case customShader
    case sprite
    case meshDisplacement
    case pointGrid
    case lineGrid
    case feedback
    case syphonInput
    case syphonOutput
    case previewOutput
    case qcInterpolation
    case qcRandom
    case qcLFO
    case qcMath
    case iterator
    case iteratorVariables
    case transformation3D
    case replicateInSpace
    case lighting
    case colorInvert
    case linearGradient
    case clear
    case renderGradient
    case billboard
    case qcSprite
    case cube
    case sphere
    case particleSystem
    // Quartz Composer's Utility > Color set. Generated definitions live in
    // QuartzComposerColorPatches.swift; the arithmetic is in QCColorMath.
    case qcColorFromComponentsRGB
    case qcColorFromComponentsHSL
    case qcColorToComponentsRGB
    case qcColorToComponentsHSL
    case qcColorMixer
    case qcColorTransform
}

struct PatchDefinition: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: PatchCategory
    let summary: String
    let ports: [PortTemplate]
    let parameters: [ParameterSchema]
    let executorKind: PatchExecutorKind

    func makeNode(at position: CanvasPoint, catalogPathID: String? = nil) -> NodeRecord {
        var node = NodeRecord(
            patchType: id,
            name: name,
            position: position,
            ports: ports.map {
                PortRecord(
                    id: PortID(),
                    key: $0.key,
                    name: $0.name,
                    direction: $0.direction,
                    dataType: $0.dataType
                )
            },
            parameters: Dictionary(
                uniqueKeysWithValues: parameters.map { ($0.key, $0.defaultValue) }),
            catalogPathID: catalogPathID
        )
        if executorKind == .customShader,
            case .string(let source) = node.parameters["shaderSource"]
        {
            node.configuration["shaderFile"] = .string("\(node.id.rawValue.uuidString).metal")
            for declaration in CustomShaderSource.parameterDeclarations(in: source) {
                node.parameters[declaration.key] = .number(declaration.defaultValue)
            }
        }
        return node
    }
}

typealias PatchDescriptor = PatchDefinition

enum PatchRegistry {
    static let namespace = "com.steolepanda.metaliquartz"

    static let builtIns: [PatchDefinition] =
        [
            PatchDefinition(
                id: "\(namespace).number",
                name: "Number",
                category: .control,
                summary: "Publishes a constant numeric value.",
                ports: [output("value", "Value", .number)],
                parameters: [.number(key: "value", name: "Value", defaultValue: 0, range: -1...1)],
                executorKind: .number
            ),
            PatchDefinition(
                id: "\(namespace).boolean",
                name: "Boolean",
                category: .control,
                summary: "Publishes an on/off value.",
                ports: [output("value", "Value", .boolean)],
                parameters: [.boolean(key: "value", name: "Value", defaultValue: false)],
                executorKind: .boolean
            ),
            PatchDefinition(
                id: "\(namespace).color",
                name: "Color",
                category: .control,
                summary: "Publishes a linear RGBA color.",
                ports: [output("color", "Color", .color)],
                parameters: [
                    .color(
                        key: "color",
                        name: "Color",
                        defaultValue: .color(red: 1, green: 1, blue: 1, alpha: 1)
                    )
                ],
                executorKind: .color
            ),
            PatchDefinition(
                id: "\(namespace).time",
                name: "Time",
                category: .control,
                summary: "Publishes composition time with speed and offset controls.",
                ports: [output("time", "Time", .number)],
                parameters: [
                    .number(key: "speed", name: "Speed", defaultValue: 1, range: -4...4),
                    .number(key: "offset", name: "Offset", defaultValue: 0, range: -60...60),
                ],
                executorKind: .time
            ),
            PatchDefinition(
                id: "\(namespace).lfo",
                name: "LFO",
                category: .control,
                summary: "Produces a periodic sine, triangle, saw, or square control signal.",
                ports: [output("value", "Value", .number)],
                parameters: [
                    .choice(
                        key: "waveform",
                        name: "Waveform",
                        defaultValue: "sine",
                        choices: ["sine", "triangle", "saw", "square"]
                    ),
                    .number(key: "frequency", name: "Frequency", defaultValue: 1, range: 0...20),
                    .number(key: "amplitude", name: "Amplitude", defaultValue: 1, range: 0...10),
                    .number(key: "offset", name: "Offset", defaultValue: 0, range: -10...10),
                ],
                executorKind: .lfo
            ),
            PatchDefinition(
                id: "\(namespace).math",
                name: "Math",
                category: .control,
                summary: "Applies a basic operation to two numbers.",
                ports: [
                    input("a", "A", .number),
                    input("b", "B", .number),
                    output("result", "Result", .number),
                ],
                parameters: [
                    .choice(
                        key: "operation",
                        name: "Operation",
                        defaultValue: "add",
                        choices: ["add", "subtract", "multiply", "divide", "minimum", "maximum"]
                    )
                ],
                executorKind: .math
            ),
            PatchDefinition(
                id: "\(namespace).map-range",
                name: "Map Range",
                category: .control,
                summary: "Remaps a number between input and output ranges.",
                ports: [input("value", "Value", .number), output("result", "Result", .number)],
                parameters: [
                    .number(
                        key: "inputMinimum", name: "Input Min", defaultValue: 0, range: -100...100),
                    .number(
                        key: "inputMaximum", name: "Input Max", defaultValue: 1, range: -100...100),
                    .number(
                        key: "outputMinimum", name: "Output Min", defaultValue: 0, range: -100...100
                    ),
                    .number(
                        key: "outputMaximum", name: "Output Max", defaultValue: 1, range: -100...100
                    ),
                    .boolean(key: "clamp", name: "Clamp", defaultValue: true),
                ],
                executorKind: .mapRange
            ),
            PatchDefinition(
                id: "\(namespace).smooth",
                name: "Smooth",
                category: .control,
                summary: "Smooths abrupt numeric changes over time.",
                ports: [input("value", "Value", .number), output("result", "Result", .number)],
                parameters: [
                    .number(key: "response", name: "Response", defaultValue: 0.2, range: 0.001...5)
                ],
                executorKind: .smooth
            ),
            PatchDefinition(
                id: "\(namespace).switch-number",
                name: "Switch",
                category: .control,
                summary: "Selects between two numeric inputs.",
                ports: [
                    input("condition", "Condition", .boolean),
                    input("falseValue", "False", .number),
                    input("trueValue", "True", .number),
                    output("result", "Result", .number),
                ],
                parameters: [],
                executorKind: .switchNumber
            ),
            PatchDefinition(
                id: "\(namespace).image-file",
                name: "Image File",
                category: .input,
                summary: "Loads an embedded still image into the graph.",
                ports: [output("image", "Image", .image)],
                parameters: [.asset(key: "assetID", name: "Image", mediaKind: .image)],
                executorKind: .unavailableImage
            ),
            PatchDefinition(
                id: "\(namespace).movie-file",
                name: "Movie File",
                category: .input,
                summary: "Plays a looping movie embedded in the composition.",
                ports: [output("image", "Image", .image)],
                parameters: [
                    .asset(key: "assetID", name: "Movie", mediaKind: .movie),
                    .boolean(key: "loop", name: "Loop", defaultValue: true),
                ],
                executorKind: .movieImage
            ),
            PatchDefinition(
                id: "\(namespace).camera",
                name: "Camera",
                category: .input,
                summary: "Captures frames from the default camera without blocking rendering.",
                ports: [output("image", "Image", .image)],
                parameters: [
                    .string(key: "deviceID", name: "Device ID", defaultValue: "")
                ],
                executorKind: .cameraImage
            ),
            PatchDefinition(
                id: "\(namespace).transform-2d",
                name: "Transform 2D",
                category: .processing,
                summary:
                    "Translates, rotates, scales, and fades an image in normalized coordinates.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [
                    .number(
                        key: "translationX", name: "Position X", defaultValue: 0, range: -1...1),
                    .number(
                        key: "translationY", name: "Position Y", defaultValue: 0, range: -1...1),
                    .number(key: "scale", name: "Scale", defaultValue: 1, range: 0.01...4),
                    .number(
                        key: "rotation", name: "Rotation", defaultValue: 0,
                        range: -3.141_593...3.141_593),
                    .number(key: "opacity", name: "Opacity", defaultValue: 1, range: 0...1),
                ],
                executorKind: .transformImage
            ),
            PatchDefinition(
                id: "\(namespace).metal-effect",
                name: "Metal Effect",
                category: .processing,
                summary: "A programmable image-processing pass backed by Metal.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [],
                executorKind: .passthroughImage
            ),
            PatchDefinition(
                id: "\(namespace).color-controls",
                name: "Color Controls",
                category: .processing,
                summary:
                    "Adjusts saturation, brightness, and contrast in a Metal-backed Core Image context.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [
                    .number(key: "saturation", name: "Saturation", defaultValue: 1, range: 0...2),
                    .number(key: "brightness", name: "Brightness", defaultValue: 0, range: -1...1),
                    .number(key: "contrast", name: "Contrast", defaultValue: 1, range: 0...4),
                ],
                executorKind: .colorControls
            ),
            PatchDefinition(
                id: "\(namespace).blend",
                name: "Blend",
                category: .processing,
                summary: "Composites foreground and background images using common blend modes.",
                ports: [
                    input("background", "Background", .image),
                    input("foreground", "Foreground", .image),
                    output("image", "Image", .image),
                ],
                parameters: [
                    .choice(
                        key: "mode",
                        name: "Mode",
                        defaultValue: "normal",
                        choices: ["normal", "add", "screen", "multiply"]
                    ),
                    .number(key: "opacity", name: "Opacity", defaultValue: 1, range: 0...1),
                ],
                executorKind: .blend
            ),
            PatchDefinition(
                id: "\(namespace).blur",
                name: "Blur",
                category: .processing,
                summary: "Applies a Gaussian blur while preserving image bounds.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [
                    .number(key: "radius", name: "Radius", defaultValue: 10, range: 0...100)
                ],
                executorKind: .blur
            ),
            PatchDefinition(
                id: "\(namespace).glow",
                name: "Glow",
                category: .processing,
                summary: "Adds a soft bloom around bright image regions.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [
                    .number(key: "radius", name: "Radius", defaultValue: 12, range: 0...100),
                    .number(key: "intensity", name: "Intensity", defaultValue: 0.8, range: 0...2),
                ],
                executorKind: .glow
            ),
            PatchDefinition(
                id: "\(namespace).displace",
                name: "Displace",
                category: .processing,
                summary: "Displaces a source image using luminance from a second image.",
                ports: [
                    input("image", "Image", .image),
                    input("displacement", "Displacement", .image),
                    output("image", "Image", .image),
                ],
                parameters: [
                    .number(key: "scale", name: "Scale", defaultValue: 40, range: -300...300)
                ],
                executorKind: .displace
            ),
            PatchDefinition(
                id: "\(namespace).custom-shader",
                name: "Metal Shader",
                category: .processing,
                summary: "Compiles an editable full-screen Metal fragment shader at runtime.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [
                    .code(
                        key: "shaderSource",
                        name: "Fragment Shader",
                        defaultValue: CustomShaderSource.defaultSource
                    )
                ],
                executorKind: .customShader
            ),
            PatchDefinition(
                id: "\(namespace).sprite",
                name: "Sprite",
                category: .rendering,
                summary: "Draws an image as a positioned, rotated, and tinted GPU sprite.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [
                    resolutionParameter,
                    .number(key: "positionX", name: "Position X", defaultValue: 0, range: -1...1),
                    .number(key: "positionY", name: "Position Y", defaultValue: 0, range: -1...1),
                    .number(key: "scale", name: "Scale", defaultValue: 1, range: 0.01...4),
                    .number(
                        key: "rotation",
                        name: "Rotation",
                        defaultValue: 0,
                        range: -3.141_593...3.141_593
                    ),
                    tintParameter,
                ],
                executorKind: .sprite
            ),
            PatchDefinition(
                id: "\(namespace).mesh-displacement",
                name: "Mesh Displacement",
                category: .rendering,
                summary: "Displaces a textured triangle grid in depth using image luminance.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: geometryParameters(),
                executorKind: .meshDisplacement
            ),
            PatchDefinition(
                id: "\(namespace).point-grid",
                name: "Point Grid",
                category: .rendering,
                summary: "Samples an image into a camera-controlled grid of GPU points.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: geometryParameters(
                    sizeParameter: .number(
                        key: "pointSize",
                        name: "Point Size",
                        defaultValue: 3,
                        range: 1...32
                    )),
                executorKind: .pointGrid
            ),
            PatchDefinition(
                id: "\(namespace).line-grid",
                name: "Line Grid / Rutt–Etra",
                category: .rendering,
                summary: "Builds luminance-displaced scan lines in the Rutt–Etra tradition.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: geometryParameters(
                    sizeParameter: .number(
                        key: "lineSize",
                        name: "Line Size",
                        defaultValue: 1.5,
                        range: 0.25...16
                    )),
                executorKind: .lineGrid
            ),
            PatchDefinition(
                id: "\(namespace).feedback",
                name: "Feedback",
                category: .processing,
                summary:
                    "Retains its input as the previous-frame image and forms an explicit cycle boundary.",
                ports: [
                    input("image", "Image", .image), output("image", "Previous Frame", .image),
                ],
                parameters: [
                    .boolean(key: "clear", name: "Clear Feedback", defaultValue: false)
                ],
                executorKind: .feedback
            ),
            PatchDefinition(
                id: "\(namespace).syphon-input",
                name: "Syphon Input",
                category: .input,
                summary: "Receives a Metal texture from a selected Syphon server.",
                ports: [output("image", "Image", .image)],
                parameters: [
                    .string(key: "serverUUID", name: "Server", defaultValue: "")
                ],
                executorKind: .syphonInput
            ),
            PatchDefinition(
                id: "\(namespace).syphon-output",
                name: "Syphon Output",
                category: .rendering,
                summary: "Publishes an image texture as a Metal-only Syphon server.",
                ports: [input("image", "Image", .image)],
                parameters: [
                    .string(
                        key: "serverName",
                        name: "Server Name",
                        defaultValue: "Metaliquartz"
                    )
                ],
                executorKind: .syphonOutput
            ),
            PatchDefinition(
                id: "\(namespace).preview-output",
                name: "Preview Output",
                category: .rendering,
                summary: "The image displayed in the editor's live preview.",
                ports: [input("image", "Image", .image)],
                parameters: [],
                executorKind: .previewOutput
            ),
            PatchDefinition(
                id: "\(namespace).qc.interpolation",
                name: "Interpolation",
                category: .control,
                summary:
                    "Quartz Composer interpolation with repeat modes and editable spline points.",
                ports: [
                    input("startValue", "Start Value", .number),
                    input("endValue", "End Value", .number),
                    output("value", "Value", .number),
                ],
                parameters: [
                    .number(
                        key: "startValue", name: "Start Value", defaultValue: 0, range: -100...100),
                    .number(key: "endValue", name: "End Value", defaultValue: 1, range: -100...100),
                    .number(
                        key: "duration", name: "Duration", defaultValue: 1, range: 0.001...3_600),
                    .choice(
                        key: "repeatMode", name: "Repeat", defaultValue: "none",
                        choices: ["none", "loop", "mirror"]),
                    .choice(
                        key: "curve", name: "Curve", defaultValue: "linear",
                        choices: [
                            "linear", "quadratic-in", "quadratic-out", "quadratic-in-out",
                            "cubic-in", "cubic-out", "cubic-in-out", "exponential-in",
                            "exponential-out", "exponential-in-out", "sinusoidal-in",
                            "sinusoidal-out", "sinusoidal-in-out", "spline",
                        ]),
                    .number(key: "tension", name: "Tension", defaultValue: 0, range: -1...1),
                    .string(
                        key: "controlPoints", name: "Spline Control Points",
                        defaultValue: "[0,0.25,0.5,0.75,1]"),
                ],
                executorKind: .qcInterpolation
            ),
            PatchDefinition(
                id: "\(namespace).qc.random",
                name: "Random",
                category: .control,
                summary: "Independent discontinuous or smooth seeded random values.",
                ports: [
                    input("minimum", "Minimum", .number),
                    input("maximum", "Maximum", .number),
                    output("value", "Value", .number),
                ],
                parameters: [
                    .number(key: "minimum", name: "Minimum", defaultValue: 0, range: -100...100),
                    .number(key: "maximum", name: "Maximum", defaultValue: 1, range: -100...100),
                    .choice(
                        key: "mode", name: "Variability", defaultValue: "discontinuous",
                        choices: ["discontinuous", "perlin"]),
                    .number(key: "rate", name: "Rate", defaultValue: 1, range: 0...100),
                    .number(key: "seed", name: "Seed", defaultValue: 0, range: 0...1_000_000),
                ],
                executorKind: .qcRandom
            ),
            PatchDefinition(
                id: "\(namespace).qc.lfo",
                name: "LFO",
                category: .control,
                summary:
                    "Quartz Composer wave generator with period, phase, PWM, amplitude, and offset.",
                ports: [output("value", "Value", .number)],
                parameters: [
                    .choice(
                        key: "waveform", name: "Waveform", defaultValue: "sin",
                        choices: [
                            "sin", "cos", "triangle", "square", "saw-up", "saw-down", "pwm",
                            "random",
                        ]),
                    .number(key: "period", name: "Period", defaultValue: 1, range: 0.001...3_600),
                    .number(key: "phase", name: "Phase", defaultValue: 0, range: -1...1),
                    .number(key: "pwmRatio", name: "PWM Ratio", defaultValue: 0.5, range: 0...1),
                    .number(
                        key: "amplitude", name: "Amplitude", defaultValue: 1, range: -100...100),
                    .number(key: "offset", name: "Offset", defaultValue: 0, range: -100...100),
                ],
                executorKind: .qcLFO
            ),
            PatchDefinition(
                id: "\(namespace).qc.math",
                name: "Math",
                category: .control,
                summary: "Applies an ordered, configurable sequence of arithmetic operations.",
                ports: [
                    input("initialValue", "Initial Value", .number),
                    input("operand", "Operand", .number),
                    output("result", "Result", .number),
                ],
                parameters: [
                    .number(
                        key: "initialValue", name: "Initial Value", defaultValue: 0,
                        range: -1_000...1_000),
                    .string(
                        key: "operations", name: "Operations",
                        defaultValue: "[{\"operation\":\"add\",\"value\":0}]"),
                ],
                executorKind: .qcMath
            ),
            PatchDefinition(
                id: "\(namespace).qc.iterator",
                name: "Iterator",
                category: .processing,
                summary: "Evaluates its owned child graph once for every iteration.",
                ports: [input("count", "Count", .number)],
                parameters: [
                    .number(key: "count", name: "Count", defaultValue: 1, range: 0...4_096)
                ],
                executorKind: .iterator
            ),
            PatchDefinition(
                id: "\(namespace).qc.iterator-variables",
                name: "Iterator Variables",
                category: .control,
                summary: "Publishes the current iterator count, index, and normalized position.",
                ports: [
                    output("count", "Count", .number),
                    output("index", "Index", .number),
                    output("position", "Position", .number),
                ],
                parameters: [],
                executorKind: .iteratorVariables
            ),
            PatchDefinition(
                id: "\(namespace).qc.transformation-3d",
                name: "3D Transformation",
                category: .processing,
                summary:
                    "Applies rotation around an origin, translation, then scale around that origin.",
                ports: [],
                parameters: qcTransformationParameters(),
                executorKind: .transformation3D
            ),
            PatchDefinition(
                id: "\(namespace).qc.replicate-in-space",
                name: "Replicate in Space",
                category: .processing,
                summary:
                    "Renders interpolated child-graph copies from identity to a final 3D transform.",
                ports: [input("copies", "Copies", .number)],
                parameters: qcReplicateParameters(),
                executorKind: .replicateInSpace
            ),
            PatchDefinition(
                id: "\(namespace).qc.lighting",
                name: "Lighting",
                category: .processing,
                summary:
                    "Evaluates its child graph with ambient light, materials, and up to eight lights.",
                ports: [],
                parameters: qcLightingParameters(),
                executorKind: .lighting
            ),
            PatchDefinition(
                id: "\(namespace).qc.color-invert",
                name: "Color Invert",
                category: .processing,
                summary: "Inverts RGB using Core Image while preserving alpha.",
                ports: [input("image", "Image", .image), output("image", "Image", .image)],
                parameters: [],
                executorKind: .colorInvert
            ),
            PatchDefinition(
                id: "\(namespace).qc.linear-gradient",
                name: "Linear Gradient",
                category: .input,
                summary: "Produces a lazy infinite Core Image linear gradient.",
                ports: [output("image", "Image", .image)],
                parameters: [
                    .number(
                        key: "point0X", name: "Point 0 (X)", defaultValue: 0, range: -4_096...4_096),
                    .number(
                        key: "point0Y", name: "Point 0 (Y)", defaultValue: 0, range: -4_096...4_096),
                    .number(
                        key: "point1X", name: "Point 1 (X)", defaultValue: 200,
                        range: -4_096...4_096),
                    .number(
                        key: "point1Y", name: "Point 1 (Y)", defaultValue: 200,
                        range: -4_096...4_096),
                    .color(
                        key: "color1", name: "Color 1",
                        defaultValue: .color(red: 1, green: 1, blue: 1, alpha: 1)),
                    .color(
                        key: "color2", name: "Color 2",
                        defaultValue: .color(red: 0, green: 0, blue: 0, alpha: 1)),
                ],
                executorKind: .linearGradient
            ),
            PatchDefinition(
                id: "\(namespace).qc.clear",
                name: "Clear",
                category: .rendering,
                summary: "Clears color and depth in consumer layer order.",
                ports: qcConsumerPorts(includeCulling: false),
                parameters: qcConsumerParameters(includeCulling: false) + [
                    .boolean(key: "clearColorEnabled", name: "Clear Color", defaultValue: true),
                    .boolean(key: "clearDepthEnabled", name: "Clear Depth", defaultValue: true),
                    .color(
                        key: "clearColor", name: "Color",
                        defaultValue: .color(red: 0, green: 0, blue: 0, alpha: 1)),
                ],
                executorKind: .clear
            ),
            PatchDefinition(
                id: "\(namespace).qc.render-gradient",
                name: "Gradient",
                category: .rendering,
                summary:
                    "Draws a full-destination directional three-stop gradient and resets depth.",
                ports: qcConsumerPorts(includeCulling: false),
                parameters: qcConsumerParameters(includeCulling: false) + [
                    .color(
                        key: "color1", name: "Color 1",
                        defaultValue: .color(red: 1, green: 1, blue: 1, alpha: 1)),
                    .color(
                        key: "color2", name: "Color 2",
                        defaultValue: .color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)),
                    .color(
                        key: "color3", name: "Color 3",
                        defaultValue: .color(red: 0, green: 0, blue: 0, alpha: 1)),
                    .number(key: "angle", name: "Direction", defaultValue: 0, range: -180...180),
                ],
                executorKind: .renderGradient
            ),
            PatchDefinition(
                id: "\(namespace).qc.billboard",
                name: "Billboard",
                category: .rendering,
                summary: "Draws an unlit viewer-facing image quad.",
                ports: qcConsumerPorts() + [
                    input("image", "Image", .image), input("mask", "Mask", .image),
                ],
                parameters: qcConsumerParameters() + qcQuadParameters(includeZ: false) + [
                    .choice(
                        key: "dimensions", name: "Dimensions", defaultValue: "automatic",
                        choices: ["automatic", "custom", "real-size"]),
                    .boolean(key: "pixelAligned", name: "Pixel Aligned", defaultValue: false),
                    .choice(
                        key: "crop", name: "Crop", defaultValue: "fit",
                        choices: ["fit", "fill", "stretch"]),
                ],
                executorKind: .billboard
            ),
            PatchDefinition(
                id: "\(namespace).qc.sprite",
                name: "Sprite",
                category: .rendering,
                summary: "Draws a textured 3D quad with blending, culling, and depth.",
                ports: qcConsumerPorts() + [
                    input("image", "Image", .image), input("mask", "Mask", .image),
                ],
                parameters: qcConsumerParameters() + qcQuadParameters(includeZ: true) + [
                    .boolean(key: "antialias", name: "Antialiased Edges", defaultValue: true)
                ],
                executorKind: .qcSprite
            ),
            PatchDefinition(
                id: "\(namespace).qc.cube",
                name: "Cube",
                category: .rendering,
                summary: "Draws a lit cube with independent face images and colors.",
                ports: qcConsumerPorts() + qcCubePorts(),
                parameters: qcConsumerParameters() + qcObjectTransformParameters()
                    + qcCubeFaceColors(),
                executorKind: .cube
            ),
            PatchDefinition(
                id: "\(namespace).qc.sphere",
                name: "Sphere",
                category: .rendering,
                summary: "Draws a lit, textured sphere with configurable tessellation.",
                ports: qcConsumerPorts() + [input("image", "Image", .image)],
                parameters: qcConsumerParameters() + qcObjectTransformParameters() + [
                    tintParameter,
                    .number(key: "diameter", name: "Diameter", defaultValue: 1, range: 0.001...10),
                    .number(key: "slices", name: "Slices", defaultValue: 32, range: 3...256),
                    .number(key: "stacks", name: "Stacks", defaultValue: 16, range: 2...256),
                ],
                executorKind: .sphere
            ),
            PatchDefinition(
                id: "\(namespace).qc.particle-system",
                name: "Particle System",
                category: .rendering,
                summary:
                    "GPU-updated 3D particles with QC-style emitter, evolution, and render state.",
                ports: qcConsumerPorts() + [input("image", "Image", .image)],
                parameters: qcConsumerParameters() + qcParticleParameters(),
                executorKind: .particleSystem
            ),
        ] + quartzComposerColorPatches

    static func definition(for id: String) -> PatchDefinition? {
        builtIns.first { $0.id == id }
    }

    private static let resolutionParameter = ParameterSchema.choice(
        key: "resolution",
        name: "Resolution",
        defaultValue: "source",
        choices: ["source", "640×360", "1280×720", "1920×1080"]
    )

    private static let tintParameter = ParameterSchema.color(
        key: "tint",
        name: "Tint",
        defaultValue: .color(red: 1, green: 1, blue: 1, alpha: 1)
    )

    private static func qcConsumerParameters(includeCulling: Bool = true) -> [ParameterSchema] {
        var parameters: [ParameterSchema] = [
            .boolean(key: "enable", name: "Enable", defaultValue: true),
            .number(key: "layer", name: "Layer", defaultValue: 0, range: -1_000...1_000),
            .choice(
                key: "blending", name: "Blending", defaultValue: "over",
                choices: ["replace", "over", "add"]),
            .choice(
                key: "depthTesting", name: "Depth Testing", defaultValue: "read-write",
                choices: ["none", "read-write", "read-only"]),
        ]
        if includeCulling {
            parameters.append(
                .choice(
                    key: "faceCulling", name: "Face Culling", defaultValue: "none",
                    choices: ["none", "back", "front", "use-model"])
            )
        }
        return parameters
    }

    private static func qcConsumerPorts(includeCulling: Bool = true) -> [PortTemplate] {
        var ports: [PortTemplate] = [
            input("enable", "Enable", .boolean),
            input("layer", "Layer", .number),
            input("blending", "Blending", .string),
            input("depthTesting", "Depth Testing", .string),
        ]
        if includeCulling {
            ports.append(input("faceCulling", "Face Culling", .string))
        }
        return ports
    }

    private static func qcTransformationParameters() -> [ParameterSchema] {
        [
            .number(key: "rotationX", name: "Rotation X", defaultValue: 0, range: -360...360),
            .number(key: "rotationY", name: "Rotation Y", defaultValue: 0, range: -360...360),
            .number(key: "rotationZ", name: "Rotation Z", defaultValue: 0, range: -360...360),
            .number(key: "originX", name: "Origin X", defaultValue: 0, range: -10...10),
            .number(key: "originY", name: "Origin Y", defaultValue: 0, range: -10...10),
            .number(key: "originZ", name: "Origin Z", defaultValue: 0, range: -10...10),
            .number(key: "translationX", name: "Translation X", defaultValue: 0, range: -10...10),
            .number(key: "translationY", name: "Translation Y", defaultValue: 0, range: -10...10),
            .number(key: "translationZ", name: "Translation Z", defaultValue: 0, range: -10...10),
            .number(key: "scaleX", name: "Scale X", defaultValue: 1, range: -10...10),
            .number(key: "scaleY", name: "Scale Y", defaultValue: 1, range: -10...10),
            .number(key: "scaleZ", name: "Scale Z", defaultValue: 1, range: -10...10),
        ]
    }

    private static func qcReplicateParameters() -> [ParameterSchema] {
        [
            .number(key: "copies", name: "Copies", defaultValue: 1, range: 0...4_096),
            .choice(
                key: "interpolation", name: "Interpolation", defaultValue: "linear",
                choices: [
                    "linear", "quadratic-in", "quadratic-out", "quadratic-in-out", "cubic-in",
                    "cubic-out", "cubic-in-out", "exponential-in", "exponential-out",
                    "exponential-in-out", "sinusoidal-in", "sinusoidal-out", "sinusoidal-in-out",
                ]),
            .number(key: "finalScaleX", name: "Final Scale X", defaultValue: 1, range: -10...10),
            .number(key: "finalScaleY", name: "Final Scale Y", defaultValue: 1, range: -10...10),
            .number(key: "finalScaleZ", name: "Final Scale Z", defaultValue: 1, range: -10...10),
            .number(
                key: "finalOrientationX", name: "Final Orientation X", defaultValue: 0,
                range: -360...360),
            .number(
                key: "finalOrientationY", name: "Final Orientation Y", defaultValue: 0,
                range: -360...360),
            .number(
                key: "finalOrientationZ", name: "Final Orientation Z", defaultValue: 0,
                range: -360...360),
            .number(key: "finalOriginX", name: "Final Origin X", defaultValue: 0, range: -10...10),
            .number(key: "finalOriginY", name: "Final Origin Y", defaultValue: 0, range: -10...10),
            .number(key: "finalOriginZ", name: "Final Origin Z", defaultValue: 0, range: -10...10),
            .number(
                key: "finalRotationX", name: "Final Rotation X", defaultValue: 0, range: -360...360),
            .number(
                key: "finalRotationY", name: "Final Rotation Y", defaultValue: 0, range: -360...360),
            .number(
                key: "finalRotationZ", name: "Final Rotation Z", defaultValue: 0, range: -360...360),
            .number(
                key: "finalTranslationX", name: "Final Translation X", defaultValue: 0,
                range: -10...10),
            .number(
                key: "finalTranslationY", name: "Final Translation Y", defaultValue: 0,
                range: -10...10),
            .number(
                key: "finalTranslationZ", name: "Final Translation Z", defaultValue: 0,
                range: -10...10),
        ]
    }

    private static func qcLightingParameters() -> [ParameterSchema] {
        var parameters: [ParameterSchema] = [
            .color(
                key: "ambient", name: "Ambient Light",
                defaultValue: .color(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)),
            .number(key: "shininess", name: "Material Shininess", defaultValue: 32, range: 0...128),
            .number(
                key: "specularity", name: "Material Specularity", defaultValue: 0.5, range: 0...1),
            .number(key: "lightCount", name: "Lights", defaultValue: 1, range: 0...8),
            .boolean(key: "twoSided", name: "Two-Sided Lighting", defaultValue: false),
            .boolean(key: "separateSpecular", name: "Separate Specular", defaultValue: false),
            .boolean(key: "shadows", name: "Shadow Maps", defaultValue: false),
            .choice(
                key: "shadowQuality", name: "Shadow Quality", defaultValue: "medium",
                choices: ["low", "medium", "high"]),
            .number(key: "polygonOffset", name: "Polygon Offset", defaultValue: 1, range: 0...16),
        ]
        for index in 1...8 {
            parameters += [
                .boolean(
                    key: "light\(index)Enabled", name: "Light \(index) Enabled",
                    defaultValue: index == 1),
                .color(
                    key: "light\(index)Color", name: "Light \(index) Color",
                    defaultValue: .color(red: 1, green: 1, blue: 1, alpha: 1)),
                .number(
                    key: "light\(index)X", name: "Light \(index) X", defaultValue: 0,
                    range: -10...10),
                .number(
                    key: "light\(index)Y", name: "Light \(index) Y", defaultValue: 0,
                    range: -10...10),
                .number(
                    key: "light\(index)Z", name: "Light \(index) Z", defaultValue: 2,
                    range: -10...10),
                .number(
                    key: "light\(index)Attenuation", name: "Light \(index) Attenuation",
                    defaultValue: 0, range: 0...10),
            ]
        }
        return parameters
    }

    private static func qcQuadParameters(includeZ: Bool) -> [ParameterSchema] {
        var parameters: [ParameterSchema] = [
            tintParameter,
            .number(key: "positionX", name: "Position X", defaultValue: 0, range: -10...10),
            .number(key: "positionY", name: "Position Y", defaultValue: 0, range: -10...10),
            .number(key: "rotationZ", name: "Rotation Z", defaultValue: 0, range: -360...360),
            .number(key: "width", name: "Width", defaultValue: 1, range: 0...10),
            .number(key: "height", name: "Height", defaultValue: 1, range: 0...10),
        ]
        if includeZ {
            parameters.insert(
                .number(key: "positionZ", name: "Position Z", defaultValue: 0, range: -10...10),
                at: 3)
            parameters += [
                .number(key: "rotationX", name: "Rotation X", defaultValue: 0, range: -360...360),
                .number(key: "rotationY", name: "Rotation Y", defaultValue: 0, range: -360...360),
            ]
        }
        return parameters
    }

    private static func qcObjectTransformParameters() -> [ParameterSchema] {
        qcTransformationParameters() + [
            .number(key: "width", name: "Width", defaultValue: 1, range: 0.001...10),
            .number(key: "height", name: "Height", defaultValue: 1, range: 0.001...10),
            .number(key: "depth", name: "Depth", defaultValue: 1, range: 0.001...10),
        ]
    }

    private static func qcCubePorts() -> [PortTemplate] {
        ["front", "back", "left", "right", "top", "bottom"].map {
            input("\($0)Image", "\($0.capitalized) Image", .image)
        }
    }

    private static func qcCubeFaceColors() -> [ParameterSchema] {
        ["Front", "Back", "Left", "Right", "Top", "Bottom"].map { face in
            .color(
                key: "\(face.lowercased())Color", name: "\(face) Color",
                defaultValue: .color(red: 1, green: 1, blue: 1, alpha: 1))
        }
    }

    private static func qcParticleParameters() -> [ParameterSchema] {
        [
            tintParameter,
            .number(key: "count", name: "Particle Count", defaultValue: 1_000, range: 0...100_000),
            .number(key: "lifetime", name: "Lifetime", defaultValue: 3, range: 0.001...300),
            .number(key: "emitterX", name: "Emitter X", defaultValue: 0, range: -10...10),
            .number(key: "emitterY", name: "Emitter Y", defaultValue: 0, range: -10...10),
            .number(key: "emitterZ", name: "Emitter Z", defaultValue: 0, range: -10...10),
            .number(
                key: "velocityMinX", name: "Velocity Min X", defaultValue: -0.2, range: -10...10),
            .number(
                key: "velocityMinY", name: "Velocity Min Y", defaultValue: 0.2, range: -10...10),
            .number(
                key: "velocityMinZ", name: "Velocity Min Z", defaultValue: -0.2, range: -10...10),
            .number(
                key: "velocityMaxX", name: "Velocity Max X", defaultValue: 0.2, range: -10...10),
            .number(key: "velocityMaxY", name: "Velocity Max Y", defaultValue: 1, range: -10...10),
            .number(
                key: "velocityMaxZ", name: "Velocity Max Z", defaultValue: 0.2, range: -10...10),
            .number(key: "sizeMin", name: "Size Min", defaultValue: 0.01, range: 0...2),
            .number(key: "sizeMax", name: "Size Max", defaultValue: 0.05, range: 0...2),
            .number(key: "gravityX", name: "Gravity X", defaultValue: 0, range: -10...10),
            .number(key: "gravityY", name: "Gravity Y", defaultValue: -0.2, range: -10...10),
            .number(key: "gravityZ", name: "Gravity Z", defaultValue: 0, range: -10...10),
            .number(key: "attraction", name: "Attraction", defaultValue: 0, range: -10...10),
            .number(key: "startupDelay", name: "Startup Delay", defaultValue: 0, range: 0...300),
            .choice(
                key: "sizeEvolution", name: "Size Evolution", defaultValue: "interpolated",
                choices: ["delta", "interpolated"]),
            .choice(
                key: "colorEvolution", name: "Color Evolution", defaultValue: "interpolated",
                choices: ["delta", "interpolated"]),
        ]
    }

    private static func geometryParameters(
        sizeParameter: ParameterSchema? = nil
    ) -> [ParameterSchema] {
        var parameters: [ParameterSchema] = [
            resolutionParameter,
            .number(key: "columns", name: "Columns", defaultValue: 64, range: 2...256),
            .number(key: "rows", name: "Rows", defaultValue: 36, range: 2...256),
            .number(
                key: "displacement",
                name: "Displacement",
                defaultValue: 0.5,
                range: -2...2
            ),
        ]
        if let sizeParameter { parameters.append(sizeParameter) }
        parameters += [
            .number(
                key: "cameraPitch",
                name: "Camera Pitch",
                defaultValue: 0,
                range: -1.5...1.5
            ),
            .number(
                key: "cameraYaw",
                name: "Camera Yaw",
                defaultValue: 0,
                range: -3.141_593...3.141_593
            ),
            .number(
                key: "cameraDistance",
                name: "Camera Distance",
                defaultValue: 2.25,
                range: 0.5...8
            ),
            tintParameter,
        ]
        return parameters
    }

    // Not private: the generated Quartz Composer definitions live in their own file and
    // build their port lists with these.
    static func input(_ key: String, _ name: String, _ type: PortDataType) -> PortTemplate {
        PortTemplate(key: key, name: name, direction: .input, dataType: type)
    }

    static func output(_ key: String, _ name: String, _ type: PortDataType) -> PortTemplate {
        PortTemplate(key: key, name: name, direction: .output, dataType: type)
    }
}

extension PatchDefinition {
    static let scaffoldCatalog = PatchRegistry.builtIns

    static func descriptor(for id: String) -> PatchDefinition? {
        PatchRegistry.definition(for: id)
    }

    var isContainer: Bool {
        switch executorKind {
        case .iterator, .transformation3D, .replicateInSpace, .lighting:
            true
        default:
            false
        }
    }

    var isConsumer: Bool {
        switch executorKind {
        case .previewOutput, .syphonOutput, .clear, .renderGradient, .billboard, .qcSprite,
            .cube, .sphere, .particleSystem:
            true
        default:
            false
        }
    }
}
