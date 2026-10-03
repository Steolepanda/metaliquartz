import AppKit
import SwiftUI

enum InterfaceStyle: String, CaseIterable, Identifiable, Sendable {
    case modern
    case legacy

    static let preferenceKey = "interfaceStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern:
            "Modern"
        case .legacy:
            "Quartz Composer 4 (Legacy)"
        }
    }

    var summary: String {
        switch self {
        case .modern:
            "The current docked Metaliquartz workspace."
        case .legacy:
            "A Quartz Composer 4-inspired editor with detachable utility panels."
        }
    }
}

enum UITestLaunchConfiguration {
    private static let environment = ProcessInfo.processInfo.environment

    static var isEnabled: Bool {
        environment["MQ_UI_TESTING"] == "1"
    }

    static var interfaceStyle: InterfaceStyle? {
        guard isEnabled, let rawValue = environment["MQ_INTERFACE_STYLE"] else {
            return nil
        }
        return InterfaceStyle(rawValue: rawValue)
    }
}

enum InterfacePreference {
    static func selectedStyle(in defaults: UserDefaults = .standard) -> InterfaceStyle? {
        guard let rawValue = defaults.string(forKey: InterfaceStyle.preferenceKey) else {
            return nil
        }
        return InterfaceStyle(rawValue: rawValue)
    }

    static func select(_ style: InterfaceStyle, in defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: InterfaceStyle.preferenceKey)
    }
}

enum NumericControlStyle: String, CaseIterable, Identifiable, Sendable {
    case sliders
    case rotaryFaders

    static let preferenceKey = "numericControlStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sliders: "Sliders"
        case .rotaryFaders: "Rotary Faders"
        }
    }
}

enum CategoryColorPreferences {
    static let revisionKey = "patchCategoryColors.revision"
    private static let prefix = "patchCategoryColors."

    static let defaultHex: [String: String] = [
        "Animation": "#C96C34",
        "Environment": "#507FBD",
        "Image": "#795CB6",
        "Interaction": "#B85F92",
        "Mesh": "#3F8F80",
        "Network": "#477EA5",
        "Processor": "#8A5DB4",
        "Program": "#64748A",
        "Render": "#438C51",
        "Graphic Animation": "#AE683C",
        "Graphic Transition": "#96566E",
        "Source": "#338A9D",
        "Utility": "#80714E",
        "Metaliquartz": "#D2752C",
    ]

    static func hex(
        for category: String,
        defaults: UserDefaults = .standard
    ) -> String {
        defaults.string(forKey: prefix + category)
            ?? defaultHex[category]
            ?? "#6B7280"
    }

    static func color(
        for category: String,
        defaults: UserDefaults = .standard
    ) -> NSColor {
        NSColor(mqHex: hex(for: category, defaults: defaults)) ?? .systemGray
    }

    static func setColor(
        _ color: NSColor,
        for category: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(color.mqHex, forKey: prefix + category)
        bumpRevision(defaults)
    }

    static func resetAll(defaults: UserDefaults = .standard) {
        for category in QuartzComposerCatalog.topLevelCategoryNames {
            defaults.removeObject(forKey: prefix + category)
        }
        bumpRevision(defaults)
    }

    private static func bumpRevision(_ defaults: UserDefaults) {
        defaults.set(defaults.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }
}

extension NSColor {
    fileprivate convenience init?(mqHex: String) {
        let value = mqHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    fileprivate var mqHex: String {
        let converted = usingColorSpace(.deviceRGB) ?? self
        return String(
            format: "#%02X%02X%02X",
            Int(round(converted.redComponent * 255)),
            Int(round(converted.greenComponent * 255)),
            Int(round(converted.blueComponent * 255))
        )
    }
}

enum LegacyPanelKind: String, CaseIterable, Sendable {
    case library
    case inspector
    case viewer

    var title: String {
        switch self {
        case .library: "Patch Library"
        case .inspector: "Patch Inspector"
        case .viewer: "Viewer"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .library: CGSize(width: 272, height: 540)
        case .inspector: CGSize(width: 320, height: 580)
        case .viewer: CGSize(width: 520, height: 390)
        }
    }
}

enum LegacyPanelPreferences {
    static func isDocked(
        _ panel: LegacyPanelKind,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key("docked", panel))
    }

    static func setDocked(
        _ docked: Bool,
        panel: LegacyPanelKind,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(docked, forKey: key("docked", panel))
    }

    static func isVisible(
        _ panel: LegacyPanelKind,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let preferenceKey = key("visible", panel)
        guard defaults.object(forKey: preferenceKey) != nil else { return true }
        return defaults.bool(forKey: preferenceKey)
    }

    static func setVisible(
        _ visible: Bool,
        panel: LegacyPanelKind,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(visible, forKey: key("visible", panel))
    }

    static func frameAutosaveName(for panel: LegacyPanelKind) -> String {
        "Metaliquartz.Legacy.\(panel.rawValue).frame"
    }

    static func constrainedFrame(
        _ frame: CGRect,
        to visibleFrame: CGRect,
        margin: CGFloat = 16
    ) -> CGRect {
        let maximumWidth = max(1, visibleFrame.width - margin * 2)
        let maximumHeight = max(1, visibleFrame.height - margin * 2)
        let width = min(frame.width, maximumWidth)
        let height = min(frame.height, maximumHeight)
        let minimumX = visibleFrame.minX + margin
        let minimumY = visibleFrame.minY + margin
        let maximumX = visibleFrame.maxX - margin - width
        let maximumY = visibleFrame.maxY - margin - height
        return CGRect(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY),
            width: width,
            height: height
        )
    }

    private static func key(_ property: String, _ panel: LegacyPanelKind) -> String {
        "legacyPanel.\(panel.rawValue).\(property)"
    }
}

struct InterfaceSettingsView: View {
    @AppStorage(InterfaceStyle.preferenceKey) private var rawStyle = ""
    @AppStorage(NumericControlStyle.preferenceKey) private var rawNumericStyle =
        NumericControlStyle.sliders.rawValue
    @AppStorage(CategoryColorPreferences.revisionKey) private var categoryColorRevision = 0

    private var style: Binding<InterfaceStyle> {
        Binding(
            get: { InterfaceStyle(rawValue: rawStyle) ?? .modern },
            set: { rawStyle = $0.rawValue }
        )
    }

    private var numericStyle: Binding<NumericControlStyle> {
        Binding(
            get: { NumericControlStyle(rawValue: rawNumericStyle) ?? .sliders },
            set: { rawNumericStyle = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Editor") {
                Picker("Interface Style", selection: style) {
                    ForEach(InterfaceStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("Numeric Controls", selection: numericStyle) {
                    ForEach(NumericControlStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text(style.wrappedValue.summary)
                    .foregroundStyle(.secondary)
            }

            Section("Patch Category Colors") {
                ForEach(QuartzComposerCatalog.topLevelCategoryNames, id: \.self) { category in
                    ColorPicker(
                        category,
                        selection: Binding(
                            get: {
                                _ = categoryColorRevision
                                return Color(nsColor: CategoryColorPreferences.color(for: category))
                            },
                            set: { newColor in
                                CategoryColorPreferences.setColor(
                                    NSColor(newColor), for: category
                                )
                            }
                        ),
                        supportsOpacity: false
                    )
                }

                Button("Reset Category Colors") {
                    CategoryColorPreferences.resetAll()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 650)
        .navigationTitle("General")
    }
}

struct InterfaceChoiceView: View {
    @AppStorage(InterfaceStyle.preferenceKey) private var rawStyle = ""

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Choose Your Workspace")
                    .font(.title2.weight(.semibold))
                Text("You can switch styles later in Metaliquartz Settings.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                ForEach(InterfaceStyle.allCases) { style in
                    Button {
                        rawStyle = style.rawValue
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Image(
                                systemName: style == .legacy
                                    ? "macwindow.on.rectangle" : "sidebar.left"
                            )
                            .font(.title2)
                            Text(style.title)
                                .font(.headline)
                            Text(style.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.separator, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Selects \(style.title) and closes this chooser")
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(.regularMaterial)
    }
}

struct EditorCommandActions {
    var showLiveSession: () -> Void
    var toggleLibrary: () -> Void
    var toggleInspector: () -> Void
    var toggleViewer: () -> Void
    var createMacro: () -> Void
}

private struct EditorCommandActionsKey: FocusedValueKey {
    typealias Value = EditorCommandActions
}

extension FocusedValues {
    var editorCommandActions: EditorCommandActions? {
        get { self[EditorCommandActionsKey.self] }
        set { self[EditorCommandActionsKey.self] = newValue }
    }
}

struct MetaliquartzCommands: Commands {
    @FocusedValue(\.editorCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Composition") {
            Button("Create Macro") {
                actions?.createMacro()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button("Live Session…") {
                actions?.showLiveSession()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Patch Library") {
                actions?.toggleLibrary()
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(actions == nil)

            Button("Patch Inspector") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(actions == nil)

            Button("Viewer") {
                actions?.toggleViewer()
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}
