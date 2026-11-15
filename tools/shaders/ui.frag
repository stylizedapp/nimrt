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
    if (inClipRect.z > inClipRect.x && inClipRect.w > inClipRect.y) {
        vec2 clipMin = inClipRect.xy;
        vec2 clipMax = inClipRect.zw;
        if (inIsText > 0.5) {
            clipMin -= vec2(2.0);
            clipMax += vec2(2.0);
        }
        if (screenPixel.x < clipMin.x || screenPixel.x > clipMax.x ||
            screenPixel.y < clipMin.y || screenPixel.y > clipMax.y) {
            discard;
        }
    }

    if (inIsText > 0.5) {
        float rawAlpha = texture(uFontTexture, inUV).r;
        if (rawAlpha < 0.005) {
            discard;
        }
        // Linear coverage rendering + perceptual gamma compensation for sRGB swapchain blending
        float alpha = pow(clamp(rawAlpha, 0.0, 1.0), 0.78);
        if (alpha < 0.005) {
            discard;
        }
        outFragColor = vec4(inColor.rgb, inColor.a * alpha);
        return;
    }

    float aa = inSoftness;
    vec2 halfSize = max(vec2(0.0), inHalfSize - vec2(aa * 0.5));
    float r = min(inRadius, min(halfSize.x, halfSize.y));
    float d = sdRoundedBox(inLocalPos, halfSize, r);

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
