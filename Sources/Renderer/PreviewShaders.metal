#include <metal_stdlib>
using namespace metal;

struct PreviewVertex {
    float4 position [[position]];
    float2 textureCoordinate;
};

struct TexturePreviewUniforms {
    float2 sourceSize;
    float2 destinationSize;
};

struct TransformUniforms {
    float2 translation;
    float scale;
    float rotation;
    float opacity;
};

vertex PreviewVertex previewVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0),
        float2(3.0, -1.0),
        float2(-1.0, 3.0),
    };
    constexpr float2 textureCoordinates[] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0),
    };

    PreviewVertex output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.textureCoordinate = textureCoordinates[vertexID];
    return output;
}

fragment half4 previewFragment(
    PreviewVertex input [[stage_in]],
    constant float &time [[buffer(0)]]
) {
    float2 uv = input.textureCoordinate;
    float2 centered = uv - 0.5;
    float radius = length(centered);
    float angle = atan2(centered.y, centered.x);

    float pulse = 0.5 + 0.5 * sin(time * 0.8 - radius * 10.0);
    float sweep = 0.5 + 0.5 * sin(angle * 3.0 + time * 0.55);
    float glow = exp(-3.2 * radius);

    float3 deepBlue = float3(0.015, 0.035, 0.18);
    float3 electricBlue = float3(0.02, 0.45, 1.0);
    float3 magenta = float3(0.95, 0.04, 0.78);
    float3 color = mix(deepBlue, electricBlue, pulse);
    color = mix(color, magenta, sweep * 0.58);
    color += float3(0.2, 0.75, 1.0) * glow * 0.5;

    return half4(half3(color), 1.0h);
}

fragment half4 texturePreviewFragment(
    PreviewVertex input [[stage_in]],
    texture2d<half> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]],
    constant TexturePreviewUniforms &uniforms [[buffer(0)]]) {
    float2 uv = input.textureCoordinate;
    float sourceAspect = uniforms.sourceSize.x / max(1.0, uniforms.sourceSize.y);
    float destinationAspect = uniforms.destinationSize.x / max(1.0, uniforms.destinationSize.y);

    if (destinationAspect > sourceAspect) {
        uv.x = (uv.x - 0.5) * destinationAspect / sourceAspect + 0.5;
    } else {
        uv.y = (uv.y - 0.5) * sourceAspect / destinationAspect + 0.5;
    }
    if (any(uv < 0.0) || any(uv > 1.0)) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    half4 color = source.sample(sourceSampler, uv);
    return half4(color.rgb, 1.0h);
}

fragment half4 transform2DFragment(
    PreviewVertex input [[stage_in]],
    texture2d<half> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]],
    constant TransformUniforms &uniforms [[buffer(0)]]) {
    float2 point = input.textureCoordinate - 0.5 - uniforms.translation * 0.5;
    float cosine = cos(-uniforms.rotation);
    float sine = sin(-uniforms.rotation);
    point = float2(
        point.x * cosine - point.y * sine,
        point.x * sine + point.y * cosine
    );
    float2 uv = point / max(0.001, uniforms.scale) + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0)) {
        return half4(0.0h);
    }
    return source.sample(sourceSampler, uv) * half(uniforms.opacity);
}

struct GeometryUniforms {
    uint2 gridSize;
    float2 outputSize;
    float displacement;
    float pointSize;
    float lineSize;
    float spriteScale;
    float spriteRotation;
    float cameraPitch;
    float cameraYaw;
    float cameraDistance;
    float2 spritePosition;
    float2 padding;
    float4 tint;
};

struct GeometryVertex {
    float4 position [[position]];
    float2 textureCoordinate;
    half4 tint;
    float pointSize [[point_size]];
};

float geometryHeight(
    texture2d<half> source,
    sampler sourceSampler,
    float2 uv
) {
    float3 color = float3(source.sample(sourceSampler, uv).rgb);
    return dot(color, float3(0.2126, 0.7152, 0.0722)) - 0.5;
}

float4 geometryProjection(float3 point, constant GeometryUniforms &uniforms) {
    float pitchCosine = cos(uniforms.cameraPitch);
    float pitchSine = sin(uniforms.cameraPitch);
    point.yz = float2(
        point.y * pitchCosine - point.z * pitchSine,
        point.y * pitchSine + point.z * pitchCosine
    );
    float yawCosine = cos(uniforms.cameraYaw);
    float yawSine = sin(uniforms.cameraYaw);
    point.xz = float2(
        point.x * yawCosine + point.z * yawSine,
        -point.x * yawSine + point.z * yawCosine
    );
    float depth = max(0.1, uniforms.cameraDistance - point.z);
    return float4(point.xy * (1.8 / depth), 0.0, 1.0);
}

GeometryVertex makeGeometryVertex(
    float4 position,
    float2 uv,
    constant GeometryUniforms &uniforms
) {
    GeometryVertex output;
    output.position = position;
    output.textureCoordinate = uv;
    output.tint = half4(uniforms.tint);
    output.pointSize = uniforms.pointSize;
    return output;
}

vertex GeometryVertex spriteGeometryVertex(
    uint vertexID [[vertex_id]],
    constant GeometryUniforms &uniforms [[buffer(0)]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    };
    constexpr float2 textureCoordinates[] = {
        float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0),
        float2(0.0, 0.0), float2(1.0, 1.0), float2(1.0, 0.0),
    };
    float2 position = positions[vertexID] * uniforms.spriteScale;
    float cosine = cos(uniforms.spriteRotation);
    float sine = sin(uniforms.spriteRotation);
    position = float2(
        position.x * cosine - position.y * sine,
        position.x * sine + position.y * cosine
    ) + uniforms.spritePosition;
    return makeGeometryVertex(
        float4(position, 0.0, 1.0),
        textureCoordinates[vertexID],
        uniforms
    );
}

vertex GeometryVertex meshGeometryVertex(
    uint vertexID [[vertex_id]],
    texture2d<half> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]],
    constant GeometryUniforms &uniforms [[buffer(0)]]) {
    constexpr uint2 corners[] = {
        uint2(0, 0), uint2(1, 0), uint2(0, 1),
        uint2(0, 1), uint2(1, 0), uint2(1, 1),
    };
    uint columns = max(2u, uniforms.gridSize.x);
    uint cell = vertexID / 6;
    uint2 coordinate = uint2(cell % (columns - 1), cell / (columns - 1));
    coordinate += corners[vertexID % 6];
    float2 uv = float2(coordinate) / float2(max(uint2(1), uniforms.gridSize - 1));
    float height = geometryHeight(source, sourceSampler, uv) * uniforms.displacement;
    float3 point = float3(uv * 2.0 - 1.0, height);
    return makeGeometryVertex(geometryProjection(point, uniforms), uv, uniforms);
}

vertex GeometryVertex pointGeometryVertex(
    uint vertexID [[vertex_id]],
    texture2d<half> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]],
    constant GeometryUniforms &uniforms [[buffer(0)]]) {
    uint columns = max(2u, uniforms.gridSize.x);
    uint2 coordinate = uint2(vertexID % columns, vertexID / columns);
    float2 uv = float2(coordinate) / float2(max(uint2(1), uniforms.gridSize - 1));
    float height = geometryHeight(source, sourceSampler, uv) * uniforms.displacement;
    float3 point = float3(uv * 2.0 - 1.0, height);
    return makeGeometryVertex(geometryProjection(point, uniforms), uv, uniforms);
}

vertex GeometryVertex lineGeometryVertex(
    uint vertexID [[vertex_id]],
    texture2d<half> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]],
    constant GeometryUniforms &uniforms [[buffer(0)]]) {
    constexpr bool endpoint[] = {false, false, true, false, true, true};
    constexpr float side[] = {1.0, -1.0, 1.0, -1.0, 1.0, -1.0};
    uint columns = max(2u, uniforms.gridSize.x);
    uint segment = vertexID / 6;
    uint row = segment / (columns - 1);
    uint column = segment % (columns - 1);
    float2 denominator = float2(max(uint2(1), uniforms.gridSize - 1));
    float2 uv0 = float2(column, row) / denominator;
    float2 uv1 = float2(column + 1, row) / denominator;
    float height0 = geometryHeight(source, sourceSampler, uv0) * uniforms.displacement;
    float height1 = geometryHeight(source, sourceSampler, uv1) * uniforms.displacement;
    float3 point0 = float3(uv0 * 2.0 - 1.0, height0);
    float3 point1 = float3(uv1 * 2.0 - 1.0, height1);
    point0.y -= height0 * 0.5;
    point1.y -= height1 * 0.5;
    float4 projected0 = geometryProjection(point0, uniforms);
    float4 projected1 = geometryProjection(point1, uniforms);
    float2 direction = normalize(projected1.xy - projected0.xy + float2(0.00001, 0.0));
    float2 normal = float2(-direction.y, direction.x);
    float2 pixelScale = 2.0 / max(float2(1.0), uniforms.outputSize);
    float2 offset = normal * uniforms.lineSize * pixelScale * side[vertexID % 6];
    bool useEndpoint = endpoint[vertexID % 6];
    float4 position = useEndpoint ? projected1 : projected0;
    position.xy += offset;
    return makeGeometryVertex(position, useEndpoint ? uv1 : uv0, uniforms);
}

fragment half4 geometryFragment(
    GeometryVertex input [[stage_in]],
    texture2d<half> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]]) {
    return source.sample(sourceSampler, input.textureCoordinate) * input.tint;
}
