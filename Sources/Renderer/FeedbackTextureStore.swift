import Foundation
@preconcurrency import Metal

@MainActor
final class FeedbackTextureStore {
    private let device: MTLDevice
    private var textures: [NodeID: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    var retainedTextureCount: Int { textures.count }

    func texture(for nodeID: NodeID) -> MTLTexture? {
        textures[nodeID]
    }

    @discardableResult
    func capture(
        nodeID: NodeID,
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        if let current = textures[nodeID], current === source { return current }
        let destination: MTLTexture
        if let current = textures[nodeID],
            current.width == source.width,
            current.height == source.height,
            current.pixelFormat == source.pixelFormat
        {
            destination = current
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width,
                height: source.height,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = .shaderRead
            guard let replacement = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            replacement.label = "Metaliquartz Feedback \(nodeID.rawValue.uuidString)"
            destination = replacement
        }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { return nil }
        encoder.label = "Feedback Frame Copy"
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: source.width, height: source.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        textures[nodeID] = destination
        return destination
    }

    func remove(nodeID: NodeID) {
        textures[nodeID] = nil
    }

    func retainOnly(nodeIDs: Set<NodeID>) {
        textures = textures.filter { nodeIDs.contains($0.key) }
    }

    func reset() {
        textures.removeAll()
    }
}
