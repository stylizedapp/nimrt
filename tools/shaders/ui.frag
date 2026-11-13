#version 450

layout(location = 0) in vec2 inLocalPos;
layout(location = 1) in vec2 inHalfSize;
layout(location = 2) in vec2 inUV;
layout(location = 3) in vec4 inColor;
layout(location = 4) in vec4 inBorderColor;
layout(location = 5) in float inRadius;
layout(location = 6) in float inBorderWidth;
layout(location = 7) in float inSoftness;
layout(location = 8) flat in vec4 inClipRect;
layout(location = 9) flat in float inIsText;

layout(binding = 0) uniform sampler2D uFontTexture;

layout(location = 0) out vec4 outFragColor;

float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
    vec2 screenPixel = gl_FragCoord.xy;
    if (inClipRect.z > 0.0 || inClipRect.w > 0.0) {
        if (screenPixel.x < inClipRect.x || screenPixel.x > inClipRect.z ||
            screenPixel.y < inClipRect.y || screenPixel.y > inClipRect.w) {
            discard;
        }
    }

    if (inIsText > 0.5) {
        float alpha = texture(uFontTexture, inUV).r;
        if (alpha < 0.005) {
            discard;
        }
        outFragColor = vec4(inColor.rgb, inColor.a * alpha);
        return;
    }

    float r = min(inRadius, min(inHalfSize.x, inHalfSize.y));
    float d = sdRoundedBox(inLocalPos, inHalfSize, r);
    float aa = inSoftness;

    float fillAlpha = clamp(0.5 - d / aa, 0.0, 1.0);
    if (fillAlpha <= 0.0) {
        discard;
    }

    if (inBorderWidth > 0.0) {
        float borderDist = d + inBorderWidth;
        float borderAlpha = clamp(0.5 - borderDist / aa, 0.0, 1.0);
        vec4 col = mix(inBorderColor, inColor, borderAlpha);
        outFragColor = vec4(col.rgb, col.a * fillAlpha);
    } else {
        outFragColor = vec4(inColor.rgb, inColor.a * fillAlpha);
    }
}
