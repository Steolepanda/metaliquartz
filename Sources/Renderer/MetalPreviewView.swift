import MetalKit
import SwiftUI

struct MetalPreviewView: View {
    let composition: CompositionFile
    let assets: [String: Data]
    let transport: PlaybackTransportState
    let diagnostics: RenderDiagnosticsModel?
    let showsHeader: Bool
    let forcedDrawableSize: CGSize?

    init(
        composition: CompositionFile,
        assets: [String: Data],
        transport: PlaybackTransportState,
        diagnostics: RenderDiagnosticsModel? = nil,
        showsHeader: Bool = true,
        forcedDrawableSize: CGSize? = nil
    ) {
        self.composition = composition
        self.assets = assets
        self.transport = transport
        self.diagnostics = diagnostics
        self.showsHeader = showsHeader
        self.forcedDrawableSize = forcedDrawableSize
    }

    private var accessibilityRenderStatus: String {
        guard let snapshot = diagnostics?.snapshot else {
            return "Rendering diagnostics unavailable"
        }
        guard snapshot.totalFrames > 0 else {
            return "Waiting for first rendered frame"
        }
        if snapshot.nodeErrors.isEmpty {
            return "Rendering \(snapshot.totalFrames) frames; no node errors"
        }
        return
            "Rendering \(snapshot.totalFrames) frames; \(snapshot.nodeErrors.count) node errors"
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    Label("Live Preview", systemImage: "play.rectangle.fill")
                        .font(.headline)
                    Spacer()
                    Text(
                        diagnostics.map {
                            "\($0.snapshot.framesPerSecond, format: .number.precision(.fractionLength(1))) FPS"
                        } ?? "60 FPS"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.bar)
            }

            MetalPreviewRepresentable(
                composition: composition,
                assets: assets,
                transport: transport,
                diagnostics: diagnostics,
                forcedDrawableSize: forcedDrawableSize
            )
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Viewer")
                    .accessibilityIdentifier("mq.viewer")
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(accessibilityRenderStatus)
                    .accessibilityIdentifier("mq.preview.status")
            }
        }
        .background(Color.black)
    }
}

private struct MetalPreviewRepresentable: NSViewRepresentable {
    let composition: CompositionFile
    let assets: [String: Data]
    let transport: PlaybackTransportState
    let diagnostics: RenderDiagnosticsModel?
    let forcedDrawableSize: CGSize?

    final class Coordinator {
        var renderer: MetalPreviewRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return unavailableView(message: "Metal is unavailable on this Mac.")
        }

        let metalView = MTKView(frame: .zero, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.clearColor = MTLClearColor(red: 0.025, green: 0.02, blue: 0.08, alpha: 1)
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        if let forcedDrawableSize {
            metalView.autoResizeDrawable = false
            metalView.drawableSize = forcedDrawableSize
        }

        do {
            let renderer = try MetalPreviewRenderer(view: metalView, diagnostics: diagnostics)
            renderer.update(composition: composition, assets: assets, transport: transport)
            context.coordinator.renderer = renderer
            metalView.delegate = renderer
            return metalView
        } catch {
            return unavailableView(message: error.localizedDescription)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let metalView = nsView as? MTKView {
            metalView.autoResizeDrawable = forcedDrawableSize == nil
            if let forcedDrawableSize { metalView.drawableSize = forcedDrawableSize }
        }
        context.coordinator.renderer?.update(
            composition: composition,
            assets: assets,
            transport: transport
        )
    }

    private func unavailableView(message: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        return label
    }
}
