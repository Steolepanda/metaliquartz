import XCTest

@testable import Metaliquartz

/// Pins the `Utility > Color` patches to the values the real Quartz Composer 4.6.2
/// framework produced.
///
/// Every expectation below was read from a live patch instance driven by
/// `Documentation/qcgather` — `QCColorToComponents`, `QCColorFromComponents`,
/// `QCColorTransform` and `QCColorMixer` — so a failure here means the clone has drifted
/// from the framework, not merely from a previous version of this file.
final class QCColorPatchTests: XCTestCase {

    // MARK: - Color to HSL / Color to RGB

    func testColorToHSLMatchesFrameworkProbe() {
        let probes: [(QCColorMath.RGBA, QCColorMath.HSL)] = [
            (
                .init(red: 1, green: 0, blue: 0, alpha: 1),
                .init(hue: 0, saturation: 1, luminosity: 0.5)
            ),
            (
                .init(red: 0, green: 1, blue: 0, alpha: 1),
                .init(hue: 1.0 / 3, saturation: 1, luminosity: 0.5)
            ),
            (
                .init(red: 0, green: 0, blue: 1, alpha: 1),
                .init(hue: 2.0 / 3, saturation: 1, luminosity: 0.5)
            ),
            (
                .init(red: 1, green: 1, blue: 1, alpha: 1),
                .init(hue: 0, saturation: 0, luminosity: 1)
            ),
            (
                .init(red: 0, green: 0, blue: 0, alpha: 1),
                .init(hue: 0, saturation: 0, luminosity: 0)
            ),
            (
                .init(red: 1, green: 0.5, blue: 0, alpha: 1),
                .init(hue: 1.0 / 12, saturation: 1, luminosity: 0.5)
            ),
            (
                .init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1),
                .init(hue: 0, saturation: 0, luminosity: 0.5)
            ),
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1),
                .init(hue: 0.75, saturation: 0.5, luminosity: 0.5)
            ),
        ]

        for (input, expected) in probes {
            let hsl = QCColorMath.hsl(from: input)
            XCTAssertEqual(hsl.hue, expected.hue, accuracy: 1e-12, "hue for \(input)")
            XCTAssertEqual(
                hsl.saturation, expected.saturation, accuracy: 1e-12, "saturation for \(input)")
            XCTAssertEqual(
                hsl.luminosity, expected.luminosity, accuracy: 1e-12, "luminosity for \(input)")
        }
    }

    func testColorToRGBPassesTheComponentsThrough() throws {
        var node = try makeNode("color-to-rgb")
        node.parameters["inputColor"] = .color(red: 0.5, green: 0.25, blue: 0.75, alpha: 1)

        let evaluation = try evaluate([node])

        XCTAssertEqual(number(evaluation, node, "output1"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(number(evaluation, node, "output2"), 0.25, accuracy: 1e-12)
        XCTAssertEqual(number(evaluation, node, "output3"), 0.75, accuracy: 1e-12)
        XCTAssertEqual(number(evaluation, node, "outputAlpha"), 1, accuracy: 1e-12)
    }

    // MARK: - RGB Color / HSL Color

    func testHSLColorMatchesFrameworkProbe() {
        let probes:
            [(
                hue: Double, saturation: Double, luminosity: Double,
                red: Double, green: Double, blue: Double
            )] = [
                (0, 1, 0.5, 1, 0, 0),
                (1.0 / 3, 1, 0.5, 0, 1, 0),
                (2.0 / 3, 1, 0.5, 0, 0, 1),
                (0, 0, 0, 0, 0, 0),
                (0, 0, 1, 1, 1, 1),
                (0.25, 0.5, 0.5, 0.5, 0.75, 0.25),
                (0.75, 0.5, 0.5, 0.5, 0.25, 0.75),
                (1.0 / 12, 1, 0.5, 1, 0.5, 0),
                (0.5, 1, 0.25, 0, 0.5, 0.5),
            ]

        for probe in probes {
            let color = QCColorMath.rgba(
                from: .init(
                    hue: probe.hue, saturation: probe.saturation,
                    luminosity: probe.luminosity),
                alpha: 1)
            let label = "hsl(\(probe.hue), \(probe.saturation), \(probe.luminosity))"
            XCTAssertEqual(color.red, probe.red, accuracy: 1e-12, "red for \(label)")
            XCTAssertEqual(color.green, probe.green, accuracy: 1e-12, "green for \(label)")
            XCTAssertEqual(color.blue, probe.blue, accuracy: 1e-12, "blue for \(label)")
        }
    }

    // MARK: - Color Transformation

    /// Hue Rotation is in degrees. Reading it as a 0…1 fraction is the obvious mistake, and
    /// it would make 30 spin the hue almost not at all.
    func testColorTransformationTreatsHueRotationAsDegrees() {
        let red = QCColorMath.RGBA(red: 1, green: 0, blue: 0, alpha: 1)
        let probes: [(rotation: Double, red: Double, green: Double, blue: Double)] = [
            (0, 1, 0, 0),
            (30, 1, 0.5, 0),
            (60, 1, 1, 0),
            (90, 0.5, 1, 0),
            (120, 0, 1, 0),
            (180, 0, 1, 1),
            (240, 0, 0, 1),
            (360, 1, 0, 0),
        ]

        for probe in probes {
            let result = QCColorMath.transform(
                red, hueRotation: probe.rotation, saturation: 1, luminosity: 1, alpha: 1)
            XCTAssertEqual(result.red, probe.red, accuracy: 1e-12, "red at \(probe.rotation)°")
            XCTAssertEqual(
                result.green, probe.green, accuracy: 1e-12, "green at \(probe.rotation)°")
            XCTAssertEqual(result.blue, probe.blue, accuracy: 1e-12, "blue at \(probe.rotation)°")
        }
    }

    /// The saturation factor scales **HSL saturation**, which is equivalent to scaling each
    /// component's distance from the HSL luminosity `(max + min) / 2`. `(1, 1, 0)` separates
    /// that from scaling about the mean: the framework gives `(0.75, 0.75, 0.25)`, whereas
    /// the mean would give `(0.833, 0.833, 0.333)`. `(0.2, 0.6, 1.0)` is already fully
    /// saturated, so any factor above 1 must leave it untouched rather than clipping it
    /// toward the luminosity.
    func testColorTransformationScalesHSLSaturation() {
        let probes: [(input: QCColorMath.RGBA, factor: Double, expected: QCColorMath.RGBA)] = [
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1), 0,
                .init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ),
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1), 0.5,
                .init(red: 0.5, green: 0.375, blue: 0.625, alpha: 1)
            ),
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1), 2,
                .init(red: 0.5, green: 0, blue: 1, alpha: 1)
            ),
            (
                .init(red: 1, green: 1, blue: 0, alpha: 1), 0.5,
                .init(red: 0.75, green: 0.75, blue: 0.25, alpha: 1)
            ),
            (
                .init(red: 1, green: 0.4, blue: 0.4, alpha: 1), 0.5,
                .init(red: 0.85, green: 0.55, blue: 0.55, alpha: 1)
            ),
            (
                .init(red: 0.2, green: 0.6, blue: 1, alpha: 1), 0.5,
                .init(red: 0.4, green: 0.6, blue: 0.8, alpha: 1)
            ),
            (
                .init(red: 0.2, green: 0.6, blue: 1, alpha: 1), 2,
                .init(red: 0.2, green: 0.6, blue: 1, alpha: 1)
            ),
        ]

        for probe in probes {
            let result = QCColorMath.transform(
                probe.input, hueRotation: 0, saturation: probe.factor, luminosity: 1, alpha: 1)
            let label = "\(probe.input) ×\(probe.factor)"
            XCTAssertEqual(result.red, probe.expected.red, accuracy: 1e-12, "red \(label)")
            XCTAssertEqual(result.green, probe.expected.green, accuracy: 1e-12, "green \(label)")
            XCTAssertEqual(result.blue, probe.expected.blue, accuracy: 1e-12, "blue \(label)")
        }
    }

    /// The luminosity factor scales HSL luminosity, so it is *not* a per-channel multiply
    /// above 1. On `(0.5, 0.25, 0.75)` a factor of 1.25 gives `(0.625, 0.4375, 0.8125)`;
    /// multiplying channels would give `(0.625, 0.3125, 0.9375)`.
    func testColorTransformationScalesHSLLuminosity() {
        let probes: [(input: QCColorMath.RGBA, factor: Double, expected: QCColorMath.RGBA)] = [
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1), 0.5,
                .init(red: 0.25, green: 0.125, blue: 0.375, alpha: 1)
            ),
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1), 1.25,
                .init(red: 0.625, green: 0.4375, blue: 0.8125, alpha: 1)
            ),
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1), 1.5,
                .init(red: 0.75, green: 0.625, blue: 0.875, alpha: 1)
            ),
            (
                .init(red: 0.5, green: 0.25, blue: 0.75, alpha: 1), 2,
                .init(red: 1, green: 1, blue: 1, alpha: 1)
            ),
            (
                .init(red: 1, green: 1, blue: 0, alpha: 1), 1.5,
                .init(red: 1, green: 1, blue: 0.5, alpha: 1)
            ),
            (
                .init(red: 0.2, green: 0.6, blue: 1, alpha: 1), 1.25,
                .init(red: 0.5, green: 0.75, blue: 1, alpha: 1)
            ),
        ]

        for probe in probes {
            let result = QCColorMath.transform(
                probe.input, hueRotation: 0, saturation: 1, luminosity: probe.factor, alpha: 1)
            let label = "\(probe.input) ×\(probe.factor)"
            XCTAssertEqual(result.red, probe.expected.red, accuracy: 1e-12, "red \(label)")
            XCTAssertEqual(result.green, probe.expected.green, accuracy: 1e-12, "green \(label)")
            XCTAssertEqual(result.blue, probe.expected.blue, accuracy: 1e-12, "blue \(label)")
        }
    }

    func testColorTransformationClampsAlpha() {
        let input = QCColorMath.RGBA(red: 0.5, green: 0.25, blue: 0.75, alpha: 0.8)

        let faded = QCColorMath.transform(
            input, hueRotation: 0, saturation: 1, luminosity: 1, alpha: 0.5)
        XCTAssertEqual(faded.alpha, 0.4, accuracy: 1e-12)

        let boosted = QCColorMath.transform(
            input, hueRotation: 0, saturation: 1, luminosity: 1, alpha: 2)
        XCTAssertEqual(boosted.alpha, 1, accuracy: 1e-12)
    }

    /// Identity factors must return the input untouched, without a lossy HSL round trip.
    func testColorTransformationIdentityIsExact() {
        let input = QCColorMath.RGBA(red: 0.3, green: 0.6, blue: 0.9, alpha: 0.7)
        let result = QCColorMath.transform(
            input, hueRotation: 0, saturation: 1, luminosity: 1, alpha: 1)

        XCTAssertEqual(result, input)
    }

    // MARK: - Color Mixer

    /// The `Interpolation` menu in index order, with black and white as the endpoints so the
    /// reading is the curve itself. The separators in the framework's menu are display-only;
    /// counting them would shift every entry and silently select the wrong easing.
    func testColorMixerInterpolationMenuMatchesFramework() {
        let black = QCColorMath.RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        let white = QCColorMath.RGBA(red: 1, green: 1, blue: 1, alpha: 1)

        let expected: [(name: String, values: [Double])] = [
            ("Linear", [0.25, 0.5, 0.75]),
            ("Quadratic In", [0.0625, 0.25, 0.5625]),
            ("Quadratic Out", [0.4375, 0.75, 0.9375]),
            ("Quadratic In-Out", [0.125, 0.5, 0.875]),
            ("Cubic In", [0.015625, 0.125, 0.421875]),
            ("Cubic Out", [0.578125, 0.875, 0.984375]),
            ("Cubic In-Out", [0.0625, 0.5, 0.9375]),
            ("Exponential In", [0.005524, 0.03125, 0.176777]),
            ("Exponential Out", [0.823223, 0.96875, 0.994476]),
            ("Exponential In-Out", [0.015625, 0.5, 0.984375]),
            ("Sinusoidal In", [0.076120, 0.292893, 0.617317]),
            ("Sinusoidal Out", [0.382683, 0.707107, 0.923880]),
            ("Sinusoidal In-Out", [0.146447, 0.5, 0.853553]),
        ]

        XCTAssertEqual(
            QCColorMath.mixerInterpolations, expected.map(\.name),
            "the interpolation menu must stay in framework index order")

        for curve in expected {
            for (amount, wanted) in zip([0.25, 0.5, 0.75], curve.values) {
                let mixed = QCColorMath.mix(
                    black, white, amount: amount, interpolation: curve.name)
                XCTAssertEqual(
                    mixed.red, wanted, accuracy: 1e-6, "\(curve.name) at mix \(amount)")
            }
        }
    }

    func testColorMixerInterpolatesAlpha() {
        let mixed = QCColorMath.mix(
            .init(red: 1, green: 0, blue: 0, alpha: 0.25),
            .init(red: 0, green: 0, blue: 1, alpha: 0.75),
            amount: 0.5,
            interpolation: "Linear"
        )

        XCTAssertEqual(mixed.red, 0.5, accuracy: 1e-12)
        XCTAssertEqual(mixed.green, 0, accuracy: 1e-12)
        XCTAssertEqual(mixed.blue, 0.5, accuracy: 1e-12)
        XCTAssertEqual(mixed.alpha, 0.5, accuracy: 1e-12)
    }

    // MARK: - Generated definitions and catalog wiring

    func testGeneratedColorPatchesUseQuartzComposerPortKeysAndOrder() throws {
        let mixer = try definition("color-mixer")

        XCTAssertEqual(mixer.name, "Color Mixer")
        XCTAssertEqual(mixer.summary, "Mixes two colors together.")
        XCTAssertEqual(mixer.executorKind, .qcColorMixer)

        // Quartz Composer enumerates these in this order; sorting them alphabetically would
        // put inputInterpolation third.
        XCTAssertEqual(
            mixer.ports.map(\.key),
            ["inputColor1", "inputColor2", "inputMix", "outputColor"])

        XCTAssertEqual(
            mixer.parameters.map(\.key),
            ["inputColor1", "inputColor2", "inputMix", "inputInterpolation"])

        let interpolation = try XCTUnwrap(
            mixer.parameters.first { $0.key == "inputInterpolation" })
        guard case .choice(_, _, let value, let choices) = interpolation else {
            return XCTFail("Interpolation should be a menu")
        }
        XCTAssertEqual(value, "Linear")
        XCTAssertEqual(choices, QCColorMath.mixerInterpolations)
    }

    func testEveryUtilityColorCatalogRowResolvesToAGeneratedDefinition() throws {
        let rows: [(name: String, slug: String)] = [
            ("Color Mixer", "color-mixer"),
            ("Color to HSL", "color-to-hsl"),
            ("Color to RGB", "color-to-rgb"),
            ("Color Transformation", "color-transformation"),
            ("HSL Color", "hsl-color"),
            ("RGB Color", "rgb-color"),
        ]

        for row in rows {
            let entry = try XCTUnwrap(
                QuartzComposerCatalog.oldEntries.first {
                    $0.path == ["Utility", "Color"] && $0.name == row.name
                },
                "no catalog row for \(row.name)")

            let id = "\(PatchRegistry.namespace).qc.\(row.slug)"
            XCTAssertEqual(entry.definitionID, id, row.name)
            XCTAssertEqual(entry.status, .functional, row.name)
            XCTAssertTrue(entry.isAddable, row.name)
            XCTAssertNotNil(PatchRegistry.definition(for: id), row.name)
            XCTAssertEqual(QuartzComposerCatalog.addableEntry(id: entry.id)?.id, entry.id, row.name)
        }
    }

    func testUtilityColorSectionListsExactlyTheSixFrameworkPatches() throws {
        let section = try XCTUnwrap(
            self.section(at: ["Utility", "Color"]),
            "Utility › Color is not in the catalog tree")

        XCTAssertEqual(
            section.entries.map(\.name),
            [
                "Color Mixer", "Color to HSL", "Color to RGB", "Color Transformation",
                "HSL Color", "RGB Color",
            ],
            "the section should keep the Library's own listing order")
    }

    // MARK: - Runtime integration

    /// Proves the executors are wired: RGB Color feeds Color to HSL through a real
    /// connection and the components come back out.
    func testRuntimeConnectsRGBColorIntoColorToHSL() throws {
        var rgb = try makeNode("rgb-color")
        rgb.parameters["input1"] = .number(0.5)
        rgb.parameters["input2"] = .number(0.25)
        rgb.parameters["input3"] = .number(0.75)
        rgb.parameters["inputAlpha"] = .number(1)

        let toHSL = try makeNode("color-to-hsl")
        let graph = GraphRecord(
            nodes: [rgb, toHSL],
            connections: [connect(rgb, "outputColor", toHSL, "inputColor")]
        )
        let evaluation = try evaluate(graph)

        XCTAssertTrue(evaluation.diagnostics.isEmpty)
        XCTAssertEqual(number(evaluation, toHSL, "output1"), 0.75, accuracy: 1e-12)
        XCTAssertEqual(number(evaluation, toHSL, "output2"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(number(evaluation, toHSL, "output3"), 0.5, accuracy: 1e-12)
    }

    func testRuntimeColorMixerHonoursTheInterpolationParameter() throws {
        var mixer = try makeNode("color-mixer")
        mixer.parameters["inputColor1"] = .color(red: 0, green: 0, blue: 0, alpha: 1)
        mixer.parameters["inputColor2"] = .color(red: 1, green: 1, blue: 1, alpha: 1)
        mixer.parameters["inputMix"] = .number(0.5)

        mixer.parameters["inputInterpolation"] = .string("Quadratic In")
        XCTAssertEqual(try mixedRed(mixer), 0.25, accuracy: 1e-12, "Quadratic In at 0.5")

        mixer.parameters["inputInterpolation"] = .string("Cubic Out")
        XCTAssertEqual(try mixedRed(mixer), 0.875, accuracy: 1e-12, "Cubic Out at 0.5")
    }

    func testRuntimeColorTransformationUsesDegreeRotation() throws {
        var transform = try makeNode("color-transformation")
        transform.parameters["inputColor"] = .color(red: 1, green: 0, blue: 0, alpha: 1)
        transform.parameters["inputHue"] = .number(120)
        transform.parameters["inputSaturation"] = .number(1)
        transform.parameters["inputLuminosity"] = .number(1)
        transform.parameters["inputAlpha"] = .number(1)

        let evaluation = try evaluate([transform])
        guard
            case .color(let red, let green, let blue, _)? = evaluation.values[
                PortAddress(nodeID: transform.id, portKey: "outputColor")
            ]
        else {
            return XCTFail("Expected a color on outputColor")
        }

        // 120° of hue rotation turns pure red into pure green.
        XCTAssertEqual(red, 0, accuracy: 1e-12)
        XCTAssertEqual(green, 1, accuracy: 1e-12)
        XCTAssertEqual(blue, 0, accuracy: 1e-12)
    }

    // MARK: - Helpers

    private func definition(_ suffix: String) throws -> PatchDefinition {
        try XCTUnwrap(PatchRegistry.definition(for: "\(PatchRegistry.namespace).qc.\(suffix)"))
    }

    /// Catalog sections nest, so a colour row lives under `Utility › Color` and not at the
    /// top level.
    private func section(at path: [String]) -> PatchCatalogSection? {
        func search(_ sections: [PatchCatalogSection]) -> PatchCatalogSection? {
            for candidate in sections {
                if candidate.path == path { return candidate }
                if let found = search(candidate.children) { return found }
            }
            return nil
        }
        return search(QuartzComposerCatalog.sections)
    }

    private func makeNode(_ suffix: String) throws -> NodeRecord {
        try definition(suffix).makeNode(at: .zero)
    }

    private func evaluate(_ nodes: [NodeRecord]) throws -> GraphEvaluation {
        try evaluate(GraphRecord(nodes: nodes, connections: []))
    }

    private func evaluate(_ graph: GraphRecord) throws -> GraphEvaluation {
        GraphRuntime(schedule: try GraphCompiler.compile(graph)).evaluate(
            context: FrameContext(time: 0, deltaTime: 1.0 / 60.0, frameIndex: 0))
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

    private func mixedRed(_ node: NodeRecord) throws -> Double {
        let evaluation = try evaluate([node])
        guard
            case .color(let red, _, _, _)? = evaluation.values[
                PortAddress(nodeID: node.id, portKey: "outputColor")
            ]
        else {
            XCTFail("Expected a color on outputColor")
            return .nan
        }
        return red
    }

    private func number(_ evaluation: GraphEvaluation, _ node: NodeRecord, _ key: String) -> Double
    {
        guard
            case .number(let value)? = evaluation.values[
                PortAddress(nodeID: node.id, portKey: key)
            ]
        else {
            XCTFail("Expected a number on \(key)")
            return .nan
        }
        return value
    }
}
