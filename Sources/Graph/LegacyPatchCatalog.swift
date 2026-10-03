import Foundation

enum PatchCatalogStatus: String, Codable, Hashable, Sendable {
    case functional
    case existingAlias
    case catalogOnly
}

struct PatchCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var path: [String]
    var name: String
    var status: PatchCatalogStatus
    var definitionID: String?

    var topLevelCategory: String { path.first ?? "Metaliquartz" }
    var pathTitle: String { path.joined(separator: " › ") }
    var isAddable: Bool { status != .catalogOnly && definitionID != nil }
}

struct PatchCatalogSection: Identifiable, Hashable, Sendable {
    var path: [String]
    var entries: [PatchCatalogEntry]
    var children: [PatchCatalogSection]

    var id: String { path.joined(separator: "/") }
    var name: String { path.last ?? "" }
}

enum QuartzComposerCatalog {
    static let oldEntries: [PatchCatalogEntry] = parse(rawSource)

    static let entries: [PatchCatalogEntry] = {
        let modern = PatchRegistry.builtIns
            .filter { !$0.id.contains(".qc.") }
            .map { definition in
                PatchCatalogEntry(
                    id: "mq.\(slug(definition.id))",
                    path: ["Metaliquartz"],
                    name: definition.name,
                    status: .functional,
                    definitionID: definition.id
                )
            }
        return oldEntries + modern
    }()

    static let topLevelCategoryNames: [String] = {
        var result: [String] = []
        for entry in entries where !result.contains(entry.topLevelCategory) {
            result.append(entry.topLevelCategory)
        }
        return result
    }()

    static let sections: [PatchCatalogSection] = buildSections(from: entries)

    static func entry(id: String?) -> PatchCatalogEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    static func addableEntry(id: String?) -> PatchCatalogEntry? {
        guard let entry = entry(id: id), entry.isAddable else { return nil }
        return entry
    }

    private static func parse(_ source: String) -> [PatchCatalogEntry] {
        var currentPath: [String] = []
        var result: [PatchCatalogEntry] = []
        var occurrences: [String: Int] = [:]

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

            if columns.count >= 2, Int(columns[0]) != nil {
                let name = columns.dropFirst().joined(separator: " ")
                guard !currentPath.isEmpty else { continue }
                let duplicateKey = (currentPath + [name]).joined(separator: "/")
                let occurrence = occurrences[duplicateKey, default: 0]
                occurrences[duplicateKey] = occurrence + 1
                let mapping = implementation(for: currentPath, name: name)
                result.append(
                    PatchCatalogEntry(
                        id: "qc.\(slug(duplicateKey)).\(occurrence)",
                        path: currentPath,
                        name: name,
                        status: mapping?.status ?? .catalogOnly,
                        definitionID: mapping?.definitionID
                    )
                )
                continue
            }

            if let path = sectionPath(for: line, currentPath: currentPath) {
                currentPath = path
            }
        }
        return result
    }

    private static func sectionPath(
        for heading: String,
        currentPath: [String]
    ) -> [String]? {
        let top = currentPath.first
        switch heading {
        case "Animation", "Environment", "Image", "Interaction", "Mesh", "Network",
            "Processor", "Program", "Graphic Animation", "Graphic Transition", "Source":
            return [heading]
        case "Render":
            return top == "Mesh" ? ["Mesh", "Render"] : ["Render"]
        case "Utility":
            if ["Environment", "Image", "Mesh"].contains(top) {
                return [top!, "Utility"]
            }
            return ["Utility"]
        case "Composite Operation", "Generator", "Gradient", "Transition":
            return top == "Image" ? ["Image", heading] : nil
        case "Filter":
            return top == "Image" ? ["Image", "Filter"] : nil
        case "Blur", "Color Adjustment", "Color Effect", "Distortion Effect",
            "Geometry Adjustment", "Gradient Adjustment", "Halftone Effect", "Reduction",
            "Sharpen", "Stylize", "Tile Effect":
            return top == "Image" ? ["Image", "Filter", heading] : nil
        case "Generator and Creation", "Filter and Transformation":
            return top == "Mesh" ? ["Mesh", heading] : nil
        case "MIDI", "OSC":
            return top == "Network" ? ["Network", heading] : nil
        case "Control and State", "Dynamics and Physics", "Mathematical", "Data":
            return top == "Processor" ? ["Processor", heading] : nil
        case "Device":
            return top == "Source" ? ["Source", "Device"] : nil
        case "Color", "Composition Repository", "Formatter", "Logic", "Numeric", "String",
            "Structure", "General Utility":
            return top == "Utility" ? ["Utility", heading] : nil
        default:
            return nil
        }
    }

    private static func implementation(
        for path: [String],
        name: String
    ) -> (status: PatchCatalogStatus, definitionID: String)? {
        let key = (path + [name]).joined(separator: "/")
        let qc = "\(PatchRegistry.namespace).qc"
        let direct: [String: String] = [
            "Animation/Interpolation": "\(qc).interpolation",
            "Animation/Random": "\(qc).random",
            "Animation/Wave Generator (LFO)": "\(qc).lfo",
            "Environment/3D Transformation": "\(qc).transformation-3d",
            "Environment/Iterator": "\(qc).iterator",
            "Environment/Iterator Variables": "\(qc).iterator-variables",
            "Environment/Lighting": "\(qc).lighting",
            "Environment/Replicate in Space": "\(qc).replicate-in-space",
            "Image/Filter/Color Effect/Color Invert": "\(qc).color-invert",
            "Image/Gradient/Linear Gradient": "\(qc).linear-gradient",
            "Processor/Mathematical/Math": "\(qc).math",
            "Render/Billboard": "\(qc).billboard",
            "Render/Clear": "\(qc).clear",
            "Render/Cube": "\(qc).cube",
            "Render/Gradient": "\(qc).render-gradient",
            "Render/Particle System": "\(qc).particle-system",
            "Render/Sphere": "\(qc).sphere",
            "Render/Sprite": "\(qc).sprite",
            "Utility/Color/Color Mixer": "\(qc).color-mixer",
            "Utility/Color/Color to HSL": "\(qc).color-to-hsl",
            "Utility/Color/Color to RGB": "\(qc).color-to-rgb",
            "Utility/Color/Color Transformation": "\(qc).color-transformation",
            "Utility/Color/HSL Color": "\(qc).hsl-color",
            "Utility/Color/RGB Color": "\(qc).rgb-color",
            "Utility/Numeric/Math": "\(qc).math",
        ]
        if let definitionID = direct[key] {
            return (.functional, definitionID)
        }

        let aliases: [String: String] = [
            "Environment/Feedback": "\(PatchRegistry.namespace).feedback",
            "Image/Filter/Blur/Gaussian Blur": "\(PatchRegistry.namespace).blur",
            "Image/Filter/Color Adjustment/Color Controls":
                "\(PatchRegistry.namespace).color-controls",
            "Image/Filter/Distortion Effect/Displacement Distortion":
                "\(PatchRegistry.namespace).displace",
            "Image/Filter/Stylize/Bloom": "\(PatchRegistry.namespace).glow",
            "Image/Utility/Image Importer": "\(PatchRegistry.namespace).image-file",
            "Source/Image Importer": "\(PatchRegistry.namespace).image-file",
            "Source/Movie Importer": "\(PatchRegistry.namespace).movie-file",
            "Source/Video Input": "\(PatchRegistry.namespace).camera",
        ]
        if let definitionID = aliases[key] {
            return (.existingAlias, definitionID)
        }
        return nil
    }

    private static func buildSections(
        from entries: [PatchCatalogEntry],
        parentPath: [String] = []
    ) -> [PatchCatalogSection] {
        var names: [String] = []
        for entry in entries
        where entry.path.count > parentPath.count
            && Array(entry.path.prefix(parentPath.count)) == parentPath
        {
            let name = entry.path[parentPath.count]
            if !names.contains(name) { names.append(name) }
        }
        return names.map { name in
            let path = parentPath + [name]
            return PatchCatalogSection(
                path: path,
                entries: entries.filter { $0.path == path },
                children: buildSections(from: entries, parentPath: path)
            )
        }
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var pendingSeparator = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    private static let rawSource = """
        Quartz Composer Patch Library
        Quartz Composer does not have one immutable master list. The Patch Library changes according to:
        	•	the Quartz Composer/macOS version;
        	•	the Core Image filters installed on that Mac;
        	•	compositions installed in the system or user Composition Repository;
        	•	third-party plug-ins and user-created virtual macros.
        Apple explicitly designed the Library to include Composition Repository files and user-created patch groups. Core Image filters are also queried from the host system, so the Image categories can differ between OS releases. The list below is therefore a reconstructed Quartz Composer 4.x/4.6 stock library, excluding obvious third-party plug-ins. (CDM Create Digital Music)
        Corrections to the original list
        	•	SD Sound Player → 3D Sound Player
        	•	Choose the Typeface does not appear to be an Apple stock patch. It was probably a custom macro, translated label, or annotation.
        	•	Apple documentation uses both 3D Transform and 3D Transformation, depending on the version.
        	•	Some versions display Wave Generator, while others identify it as LFO.
        	•	Entries under Graphic Animation, Graphic Transition, Image Filter, and Composition Repository are partly dynamic.

        Library
        Animation
        	1	Interpolation
        	2	Random
        	3	Stop Watch
        	4	Timeline
        	5	Wave Generator (LFO)

        Environment
        	1	3D Sound Player
        	2	3D Transformation
        	3	Anchor Position
        	4	Feedback
        	5	Fog
        	6	FPS Display
        	7	Frame Number
        	8	Host Info
        	9	Iterator
        	10	Iterator Variables
        	11	Lighting
        	12	OpenCL Context Info — Deprecated
        	13	OpenGL Info
        	14	Patch Time
        	15	Quartz Composer Info
        	16	Render in Image
        	17	Rendering Destination Dimensions
        	18	Replicate in Space
        	19	Scaled Destination Dimensions
        	20	System Time
        	21	TrackBall
        Utility
        These are Library tags, so duplication with the parent Environment category is normal.
        	1	Anchor Position
        	2	Feedback
        	3	FPS Display
        	4	Frame Number
        	5	Host Info
        	6	Iterator Variables
        	7	OpenCL Context Info — Deprecated
        	8	OpenGL Info
        	9	Patch Time
        	10	Quartz Composer Info
        	11	Rendering Destination Dimensions
        	12	Scaled Destination Dimensions
        	13	System Time
        Apple added or substantially updated several of these patches in Quartz Composer 4, including 3D Sound Player, Feedback, Iterator, Lighting and the mesh/OpenCL tools. (CDM Create Digital Music)

        Image
        Composite Operation
        The exact names available depend on the installed Core Image version.
        	1	Addition
        	2	Blend With Alpha Mask
        	3	Blend With Blue Mask
        	4	Blend With Mask
        	5	Color Blend Mode
        	6	Color Burn Blend Mode
        	7	Color Dodge Blend Mode
        	8	Darken Blend Mode
        	9	Difference Blend Mode
        	10	Exclusion Blend Mode
        	11	Hard Light Blend Mode
        	12	Hue Blend Mode
        	13	Lighten Blend Mode
        	14	Luminosity Blend Mode
        	15	Maximum Compositing
        	16	Minimum Compositing
        	17	Multiply Compositing
        	18	Multiply Blend Mode
        	19	Overlay Blend Mode
        	20	Saturation Blend Mode
        	21	Screen Blend Mode
        	22	Soft Light Blend Mode
        	23	Source Atop Compositing
        	24	Source In Compositing
        	25	Source Out Compositing
        	26	Source Over Compositing
        Some installations expose additional Core Image compositing operations.

        Filter
        Blur
        	1	Box Blur
        	2	Disc Blur
        	3	Fast Box Blur
        	4	Fast Disc Blur
        	5	Gaussian Blur
        	6	Masked Variable Blur
        	7	Median Filter
        	8	Motion Blur
        	9	Noise Reduction
        	10	Zoom Blur
        Color Adjustment
        	1	Color Clamp
        	2	Color Controls
        	3	Color Matrix
        	4	Color Polynomial
        	5	Exposure Adjust
        	6	Gamma Adjust
        	7	Hue Adjust
        	8	Linear to sRGB Tone Curve
        	9	sRGB Tone Curve to Linear
        	10	Temperature and Tint
        	11	Tone Curve
        	12	Vibrance
        	13	White Point Adjust
        Color Effect
        	1	Color Cross Polynomial
        	2	Color Cube
        	3	Color Cube With Color Space
        	4	Color Invert
        	5	Color Map
        	6	Color Monochrome
        	7	Color Posterize
        	8	False Color
        	9	Lab Delta E
        	10	Mask to Alpha
        	11	Maximum Component
        	12	Minimum Component
        	13	Photo Effect Chrome
        	14	Photo Effect Fade
        	15	Photo Effect Instant
        	16	Photo Effect Mono
        	17	Photo Effect Noir
        	18	Photo Effect Process
        	19	Photo Effect Tonal
        	20	Photo Effect Transfer
        	21	Sepia Tone
        	22	Spot Color
        	23	Vignette
        	24	Vignette Effect
        Many of the “Photo Effect” filters appeared after the original Snow Leopard release, so they will not exist in every Quartz Composer installation.
        Distortion Effect
        	1	Bump Distortion
        	2	Bump Distortion Linear
        	3	Circle Splash Distortion
        	4	Circular Wrap Distortion
        	5	Displacement Distortion
        	6	Droste
        	7	Glass Distortion
        	8	Glass Lozenge
        	9	Hole Distortion
        	10	Light Tunnel
        	11	Pinch Distortion
        	12	Stretch Crop
        	13	Torus Lens Distortion
        	14	Twirl Distortion
        	15	Vortex Distortion
        Geometry Adjustment
        	1	Affine Clamp
        	2	Affine Transform
        	3	Crop
        	4	Lanczos Scale Transform
        	5	Perspective Correction
        	6	Perspective Rotate
        	7	Perspective Transform
        	8	Straighten Filter
        Gradient Adjustment
        	1	Smooth Linear Gradient
        Halftone Effect
        	1	Circular Screen
        	2	CMYK Halftone
        	3	Dot Screen
        	4	Hatched Screen
        	5	Line Screen
        Reduction
        	1	Area Average
        	2	Area Bounds Red
        	3	Area Histogram
        	4	Area Logarithmic Histogram
        	5	Area Maximum
        	6	Area Maximum Alpha
        	7	Area Minimum
        	8	Area Minimum Alpha
        	9	Column Average
        	10	Histogram Display Filter
        	11	Row Average
        Sharpen
        	1	Sharpen Luminance
        	2	Unsharp Mask
        Stylize
        	1	Blend With Alpha Mask
        	2	Blend With Blue Mask
        	3	Blend With Mask
        	4	Bloom
        	5	Comic Effect
        	6	Crystallize
        	7	Depth of Field
        	8	Edges
        	9	Edge Work
        	10	Gloom
        	11	Height Field From Mask
        	12	Hexagonal Pixellate
        	13	Highlight and Shadow Adjust
        	14	Line Overlay
        	15	Pixellate
        	16	Pointillize
        	17	Shaded Material
        	18	Spot Light
        Tile Effect
        	1	Affine Tile
        	2	Eightfold Reflected Tile
        	3	Fourfold Reflected Tile
        	4	Fourfold Rotated Tile
        	5	Fourfold Translated Tile
        	6	Glide Reflected Tile
        	7	Kaleidoscope
        	8	Op Tile
        	9	Parallelogram Tile
        	10	Perspective Tile
        	11	Sixfold Reflected Tile
        	12	Sixfold Rotated Tile
        	13	Triangle Kaleidoscope
        	14	Triangle Tile
        	15	Twelvefold Reflected Tile
        The Core Image catalogue evolved considerably between OS X releases. Consequently, these Filter and Composite Operation subsections should be treated as a superset, not as a guarantee that every patch will appear on one machine. Quartz Composer inherited a large part of its image-processing catalogue directly from Core Image. (ptgmedia.pearsoncmg.com)

        Generator
        	1	Checkerboard
        	2	Constant Color
        	3	Image With String
        	4	Lenticular Halo
        	5	Mesh Generator
        	6	Random Generator
        	7	Star Shine
        	8	Stripes
        	9	Sunbeams
        Depending on the version, some Core Image generators may also appear:
        	10	Aztec Code Generator
        	11	Barcode Generator
        	12	Code 128 Barcode Generator
        	13	Lenticular Halo Generator
        	14	PDF417 Barcode Generator
        	15	QR Code Generator
        The barcode generators are from later Core Image releases and are not part of the original Quartz Composer 4.0 catalogue.

        Gradient
        	1	Gaussian Gradient
        	2	Linear Gradient
        	3	Radial Gradient
        	4	Smooth Linear Gradient

        Transition
        	1	Accordion Fold Transition
        	2	Bars Swipe Transition
        	3	Copy Machine Transition
        	4	Disintegrate With Mask Transition
        	5	Dissolve Transition
        	6	Flash Transition
        	7	Mod Transition
        	8	Page Curl Transition
        	9	Page Curl With Shadow Transition
        	10	Ripple Transition
        	11	Swipe Transition
        Accordion Fold and Page Curl With Shadow are version-dependent additions.

        Utility
        	1	Core Image Filter
        	2	Crop to Destination
        	3	Crop to Reference
        	4	Image Crop
        	5	Image Dimensions
        	6	Image Downloader
        	7	Image Importer
        	8	Image Origin
        	9	Image Pixel
        	10	Image Resize
        	11	Image Texturing Properties
        	12	Image Transform
        	13	Limit to Destination
        	14	Scaled Image Dimensions
        	15	Validate Image

        Interaction
        	1	Apple Remote
        	2	HID Input
        	3	Interaction
        	4	Keyboard
        	5	Mouse
        	6	Tablet
        Some Apple hardware-specific input patches only appear on systems that support the corresponding device.

        Mesh
        Generator and Creation
        	1	Grid Indices Generator
        	2	Grid Normals Generator
        	3	Mesh Creator
        	4	Mesh Generator
        	5	Mesh Importer
        Filter and Transformation
        	1	Mesh Bend
        	2	Mesh Bulge
        	3	Mesh Jiggle
        	4	Mesh Noise
        	5	Mesh Transform
        	6	Mesh Twist
        	7	Mesh Wave
        Utility
        	1	Get Mesh Component
        	2	Get Mesh Texture
        	3	Mesh Normals Display
        	4	Mesh Vertices Display
        	5	Set Mesh Component
        	6	Set Mesh Texture
        Render
        	1	Mesh Renderer
        Quartz Composer 4 introduced the mesh datatype and added the Mesh Creator, Mesh Importer, Mesh Renderer, Mesh Transform and get/set component and texture patches. Some deformation patches, such as Mesh Bend and Mesh Wave, are Apple Composition Repository macros rather than primitive patches. (CDM Create Digital Music)

        Network
        	1	Bonjour Services
        	2	Network Broadcaster
        	3	Network Receiver
        	4	Network Synchronizer
        	5	RSS Importer
        	6	XML Importer
        MIDI
        	1	MIDI Clock Receiver
        	2	MIDI Controllers Receiver
        	3	MIDI Controllers Sender
        	4	MIDI Notes Receiver
        Some plug-ins add a MIDI Notes Sender, but it should not be assumed to be part of every stock installation.
        OSC
        	1	OSC Receiver
        	2	OSC Sender
        Quartz Composer’s network support was substantially expanded in Leopard, including native OSC transmission and reception. (Wikipedia)

        Processor
        Control and State
        	1	Accumulator
        	2	Conditional
        	3	Counter
        	4	Demultiplexer
        	5	Flip-Flop
        	6	Input Splitter
        	7	Multiplexer
        	8	Pulse
        	9	Queue
        	10	Sample & Hold
        	11	Smooth
        	12	Toggle
        	13	Watcher
        Dynamics and Physics
        	1	Force
        	2	Inertia
        	3	Spring
        Mathematical
        	1	Logic
        	2	Math
        	3	Mathematical Expression
        	4	Range
        	5	Round
        Data
        	1	Structure Count
        	2	Structure Index Member
        	3	Structure Key Member
        	4	Structure Range
        	5	Structure Reverse
        	6	Structure Sort

        Program
        	1	Core Image Filter
        	2	GLSL Shader
        	3	JavaScript
        	4	OpenCL Kernel — Deprecated
        The Core Image Filter patch lets a custom Core Image kernel be implemented inside a composition. OpenCL support arrived with Quartz Composer 4 but is deprecated on current macOS systems. (Wikipedia)

        Render
        	1	Billboard
        	2	Clear
        	3	Cube
        	4	Cylinder
        	5	Gradient
        	6	Image
        	7	Line
        	8	Mesh Renderer
        	9	Particle System
        	10	Sphere
        	11	Sprite
        Graphic Animation
        This category displays compatible compositions from the Composition Repository rather than a fixed set of primitive patches. Common Apple-supplied examples included:
        	1	2D Fluid Simulation
        	2	ASCII Art
        	3	City Lights
        	4	Concert
        	5	GLSL Grid
        	6	Grid
        	7	Moving Shapes
        	8	Plasma
        	9	Snow
        	10	Star Field
        The exact entries depend on the contents of:
        	•	/System/Library/Compositions
        	•	/Library/Compositions
        	•	~/Library/Compositions
        A default OS X 10.7 installation reportedly contained approximately 102 system compositions, but only those matching the selected protocol and Library filters are displayed. (Graham Thorne [skulpture])
        Graphic Transition
        Common Composition Repository transitions included:
        	1	Fade
        	2	Push
        	3	Swing
        	4	Zoom Dissolve
        Core Image transitions may also appear here depending on how the Library is filtered.

        Source
        	1	Audio Input
        	2	Composition Importer
        	3	Directory Scanner
        	4	Image Importer
        	5	Movie Importer
        	6	RSS Importer
        	7	Video Input
        	8	XML Importer
        Device
        	1	Apple Remote
        	2	Audio Input
        	3	HID Input
        	4	Keyboard
        	5	MIDI Clock Receiver
        	6	MIDI Controllers Receiver
        	7	MIDI Notes Receiver
        	8	Mouse
        	9	Tablet
        	10	Video Input

        Utility
        Color
        	1	Color Mixer
        	2	Color to HSL
        	3	Color to RGB
        	4	Color Transformation
        	5	HSL Color
        	6	RGB Color

        Composition Repository
        	1	Composition Importer
        	2	Composition Info
        	3	Composition Repository
        The repository is inherently extensible: installing a .qtz composition in one of the repository folders can make it appear as a reusable Library element. (leopard-adc.pepas.com)

        Formatter
        	1	Date Formatter
        	2	Number Formatter

        Logic
        	1	Conditional
        	2	Flip-Flop
        	3	Logic
        	4	Toggle

        Numeric
        	1	Accumulator
        	2	Counter
        	3	Math
        	4	Mathematical Expression
        	5	Pixels to Units
        	6	Range
        	7	Round
        	8	Units to Pixels

        String
        	1	String Case
        	2	String Compare
        	3	String Components
        	4	String Length
        	5	String Printer
        	6	String Replace
        	7	String Scanner
        	8	String Subrange
        	9	String Truncate

        Structure
        	1	Structure Count
        	2	Structure Index Member
        	3	Structure Key Member
        	4	Structure Range
        	5	Structure Reverse
        	6	Structure Sort

        General Utility
        These patches may appear directly under Utility rather than within one of its subcategories:
        	1	Demultiplexer
        	2	Input Splitter
        	3	Multiplexer
        	4	Queue
        	5	Sample & Hold
        	6	Watcher

        Reliability note
        The most defensible interpretation is that this is a normalized superset of the native Quartz Composer 4.x Library, not a literal screenshot transcription from one release. A machine running Quartz Composer 4.0 on Snow Leopard will show fewer Core Image patches than Quartz Composer 4.6 on a later OS. Conversely, later macOS releases may hide or break older QuickTime, OpenCL, device and repository elements. Third-party packages such as Kineme, Syphon, V002 and Origami can add dozens or hundreds of additional patches and should be documented separately. (docs.vidvox.net)
        """
}
