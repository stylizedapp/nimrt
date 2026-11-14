#version 450

layout(push_constant) uniform PushConstants {
    vec2 uResolution;
} push;

layout(location = 0) in vec2 inVertexPos;

layout(location = 1) in vec2 inPos;
layout(location = 2) in vec2 inSize;
layout(location = 3) in vec2 inUvPos;
layout(location = 4) in vec2 inUvSize;
layout(location = 5) in uint inColor;
layout(location = 6) in uint inBorderColor;
layout(location = 7) in float inCornerRadius;
layout(location = 8) in float inBorderWidth;
layout(location = 9) in float inSoftness;
layout(location = 10) in vec4 inClipRect;

layout(location = 0) out vec2 outLocalPos;
layout(location = 1) out vec2 outHalfSize;
layout(location = 2) out vec2 outUV;
layout(location = 3) out vec4 outColor;
layout(location = 4) out vec4 outBorderColor;
layout(location = 5) out float outRadius;
layout(location = 6) out float outBorderWidth;
layout(location = 7) out float outSoftness;
layout(location = 8) flat out vec4 outClipRect;
layout(location = 9) flat out float outIsText;

vec4 unpackRGBA(uint c) {
    return vec4(
        float((c >> 24u) & 0xFFu) / 255.0,
        float((c >> 16u) & 0xFFu) / 255.0,
        float((c >> 8u) & 0xFFu) / 255.0,
        float(c & 0xFFu) / 255.0
    );
}

void main() {
    vec2 pixelPos = inPos + inVertexPos * inSize;
    vec2 ndc = (pixelPos / push.uResolution) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);

    outHalfSize = inSize * 0.5;
    outLocalPos = (inVertexPos - 0.5) * inSize;
    outUV = inUvPos + inVertexPos * inUvSize;
    outColor = unpackRGBA(inColor);
    outBorderColor = unpackRGBA(inBorderColor);
    outRadius = inCornerRadius;
    outBorderWidth = inBorderWidth;
    outSoftness = max(inSoftness, 1.0);
    outClipRect = inClipRect;
    outIsText = (inUvSize.x > 0.0) ? 1.0 : 0.0;
}
