import XCTest

@MainActor
final class GoldenAuthoringJourneyUITests: XCTestCase {
    func testModernGoldenAuthoringJourney() throws {
        try runGoldenJourney(interfaceStyle: "modern")
    }

    func testLegacyGoldenAuthoringJourney() throws {
        try runGoldenJourney(interfaceStyle: "legacy")
    }

    private func runGoldenJourney(interfaceStyle: String) throws {
        let packageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Metaliquartz-\(interfaceStyle)-\(UUID().uuidString).mquartz",
            isDirectory: true
        )
        defer {
            if FileManager.default.fileExists(atPath: packageURL.path) {
                try? FileManager.default.removeItem(at: packageURL)
            }
        }

        let app = XCUIApplication()
        app.terminate()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        app.launchEnvironment["MQ_UI_TESTING"] = "1"
        app.launchEnvironment["MQ_INTERFACE_STYLE"] = interfaceStyle
        app.launch()
        addTeardownBlock {
            app.terminate()
        }
        if app.windows["open-panel"].firstMatch.waitForExistence(timeout: 1) {
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey("n", modifierFlags: .command)
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["mq.patch-library"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["mq.inspector"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(element("mq.preview.status", in: app).waitForExistence(timeout: 5))

        assertCatalogOnlyPatchCannotBeAdded(in: app)
        addPatch(
            named: "Linear Gradient",
            entryIdentifier: "qc.image-gradient-linear-gradient.0",
            expectedPatchCount: 1,
            in: app
        )
        addPatch(
            named: "Color Invert",
            entryIdentifier: "qc.image-filter-color-effect-color-invert.0",
            expectedPatchCount: 2,
            in: app
        )
        addPatch(
            named: "Preview Output",
            entryIdentifier: "mq.com-steolepanda-metaliquartz-preview-output",
            expectedPatchCount: 3,
            in: app
        )

        connect(
            "mq.graph.node.linear-gradient.port.output.image",
            to: "mq.graph.node.color-invert.port.input.image",
            expectedConnectionCount: 1,
            in: app
        )
        connect(
            "mq.graph.node.color-invert.port.output.image",
            to: "mq.graph.node.preview-output.port.input.image",
            expectedConnectionCount: 2,
            in: app
        )
        setGradientParameterTo45(in: app)
        assertRenderingIsHealthy(in: app)

        saveDocument(at: packageURL, in: app)
        XCTAssertTrue(
            waitUntil(timeout: 10) {
                FileManager.default.fileExists(atPath: packageURL.path)
            }
        )

        app.typeKey("w", modifierFlags: .command)
        openDocument(at: packageURL, in: app)

        assertCanvas(patches: 3, connections: 2, in: app)
        assertGradientParameterIs45(in: app)
        assertRenderingIsHealthy(in: app)
        app.terminate()
    }

    private func assertCatalogOnlyPatchCannotBeAdded(in app: XCUIApplication) {
        search("Stop Watch", in: app)
        let entry =
            app.staticTexts["mq.patch-library.entry.qc.animation-stop-watch.0"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()
        XCTAssertFalse(app.buttons["mq.patch-library.add"].isEnabled)
    }

    private func addPatch(
        named name: String,
        entryIdentifier: String,
        expectedPatchCount: Int,
        in app: XCUIApplication
    ) {
        search(name, in: app)
        let entry = app.staticTexts["mq.patch-library.entry.\(entryIdentifier)"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()
        let addButton = app.buttons["mq.patch-library.add"]
        XCTAssertTrue(waitUntil(timeout: 5) { addButton.isEnabled })
        addButton.click()
        assertCanvas(patches: expectedPatchCount, connections: 0, in: app)
    }

    private func search(_ text: String, in app: XCUIApplication) {
        let searchField = app.textFields["mq.patch-library.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText(text)
    }

    private func connect(
        _ outputIdentifier: String,
        to inputIdentifier: String,
        expectedConnectionCount: Int,
        in app: XCUIApplication
    ) {
        let output = app.buttons[outputIdentifier]
        let input = app.buttons[inputIdentifier]
        XCTAssertTrue(output.waitForExistence(timeout: 5))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        output.press(forDuration: 0.2, thenDragTo: input)
        assertCanvas(patches: 3, connections: expectedConnectionCount, in: app)
    }

    private func setGradientParameterTo45(in app: XCUIApplication) {
        let gradient = element("mq.graph.node.linear-gradient", in: app)
        XCTAssertTrue(gradient.waitForExistence(timeout: 5))
        gradient.click()
        let field = app.textFields["mq.inspector.parameter.point1X"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("45")
        field.typeKey(.return, modifierFlags: [])
        assertGradientParameterIs45(in: app)
    }

    private func assertGradientParameterIs45(in app: XCUIApplication) {
        let gradient = element("mq.graph.node.linear-gradient", in: app)
        XCTAssertTrue(gradient.waitForExistence(timeout: 5))
        gradient.click()
        let field = app.textFields["mq.inspector.parameter.point1X"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "45")
    }

    private func assertCanvas(
        patches: Int,
        connections: Int,
        in app: XCUIApplication
    ) {
        let canvas = element("mq.graph.canvas", in: app)
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let predicate = NSPredicate { evaluated, _ in
            guard let canvas = evaluated as? XCUIElement,
                let value = canvas.value as? String
            else { return false }
            return value.contains("\(patches) patches, \(connections) connections")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    private func assertRenderingIsHealthy(in app: XCUIApplication) {
        let status = element("mq.preview.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let predicate = NSPredicate { evaluated, _ in
            guard let status = evaluated as? XCUIElement
            else { return false }
            return status.label.contains("Rendering ")
                && status.label.contains("no node errors")
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func saveDocument(at url: URL, in app: XCUIApplication) {
        app.typeKey("s", modifierFlags: .command)
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.typeKey("g", modifierFlags: [.command, .shift])
        panel.typeText(url.deletingLastPathComponent().path)
        panel.typeKey(.return, modifierFlags: [])

        let nameField = panel.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(url.lastPathComponent)
        panel.buttons["Save"].click()
    }

    private func openDocument(at url: URL, in app: XCUIApplication) {
        app.typeKey("o", modifierFlags: .command)
        let panel = app.windows["open-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let locationSheet = panel.sheets.firstMatch
        XCTAssertTrue(locationSheet.waitForExistence(timeout: 5))
        let locationField = locationSheet.textFields.firstMatch
        XCTAssertTrue(locationField.waitForExistence(timeout: 5))
        locationField.typeText(url.path)
        locationField.typeKey(.return, modifierFlags: [])

        let openButton = panel.buttons["Open"]
        if openButton.waitForExistence(timeout: 2) {
            openButton.click()
        }
        XCTAssertTrue(element("mq.graph.canvas", in: app).waitForExistence(timeout: 10))
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
