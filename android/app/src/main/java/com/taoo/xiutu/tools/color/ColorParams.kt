package com.taoo.xiutu.tools.color

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlinx.serialization.Serializable

/** 三个分量（颜色偏移、权重）。 */
@Serializable
data class V3(val x: Float, val y: Float, val z: Float) {
    val isZero get() = x == 0f && y == 0f && z == 0f
    fun array() = floatArrayOf(x, y, z)

    companion object {
        val ZERO = V3(0f, 0f, 0f)
    }
}

/**
 * 一组颜色调整参数（照搬 iOS ColorMath.swift 的 ColorParams）。所有计算在 gamma 空间做。
 * 数值范围基本是 -1...1（fade 是 0...1）。
 *
 * 用法：
 * - GPU：着色器里拼上 `ColorParams.glsl("cp")`，就有 `vec3 cp_map(vec3 c)`；
 *   跑 pass 时把 `params.uniforms("cp")` 并进 uniforms。前缀不同就能在一个着色器里放好几组。
 * - CPU：`map(r, g, b)`，和着色器逐项一致（单元测试、烘 LUT 用）。
 */
data class ColorParams(
    var exposure: Float = 0f,
    var brightness: Float = 0f,
    var contrast: Float = 0f,
    var highlights: Float = 0f,
    var shadows: Float = 0f,
    var saturation: Float = 0f,
    var vibrance: Float = 0f,
    var temperature: Float = 0f,
    var tint: Float = 0f,
    var fade: Float = 0f,
    var mono: Boolean = false,
    var monoWeights: V3 = V3(0.299f, 0.587f, 0.114f),
    /** 分离色调：暗部和亮部各自叠加的颜色偏移。 */
    var shadowTint: V3 = V3.ZERO,
    var highlightTint: V3 = V3.ZERO,
) {
    val isIdentity get() = this == ColorParams()

    /** 着色器要的 uniform。 */
    fun uniforms(p: String = "cp"): Map<String, Any> = mapOf(
        "${p}_a" to floatArrayOf(exposure, brightness, contrast, highlights),
        "${p}_b" to floatArrayOf(shadows, saturation, vibrance, temperature),
        "${p}_c" to floatArrayOf(tint, fade, if (mono) 1f else 0f, 0f),
        "${p}_w" to monoWeights.array(),
        "${p}_st" to shadowTint.array(),
        "${p}_ht" to highlightTint.array(),
    )

    /** CPU 版本，和 glsl() 一致。输入输出都是 0...1。 */
    fun map(r0: Float, g0: Float, b0: Float): FloatArray {
        var r = r0; var g = g0; var b = b0
        fun luma() = r * 0.299f + g * 0.587f + b * 0.114f
        if (exposure != 0f) { val k = 2f.pow(exposure * 0.9f); r *= k; g *= k; b *= k }
        if (temperature != 0f || tint != 0f) {
            r *= 1 + 0.16f * temperature + 0.04f * tint
            g *= 1 - 0.10f * tint
            b *= 1 - 0.16f * temperature + 0.04f * tint
        }
        r = r.coerceIn(0f, 1f); g = g.coerceIn(0f, 1f); b = b.coerceIn(0f, 1f)
        if (mono) {
            val m = (r * monoWeights.x + g * monoWeights.y + b * monoWeights.z).coerceIn(0f, 1f)
            r = m; g = m; b = m
        }
        if (brightness != 0f) {
            val e = 2f.pow(-brightness * 0.8f)
            r = r.pow(e); g = g.pow(e); b = b.pow(e)
        }
        if (contrast > 0) {
            fun s(c: Float) = if (c < 0.5f) c * c * 2 else 1 - (1 - c) * (1 - c) * 2
            val k = contrast * 0.75f
            r += (s(r) - r) * k; g += (s(g) - g) * k; b += (s(b) - b) * k
        } else if (contrast < 0) {
            val k = 1 + contrast * 0.6f
            r = 0.5f + (r - 0.5f) * k; g = 0.5f + (g - 0.5f) * k; b = 0.5f + (b - 0.5f) * k
        }
        if (highlights != 0f || shadows != 0f) {
            val l = max(luma(), 0.0001f)
            val il = 1 - l
            val ws = 9.48f * l * il * il * il
            val wh = 9.48f * il * l * l * l
            val k = (l + 0.1f * shadows * ws + 0.1f * highlights * wh) / l
            r *= k; g *= k; b *= k
        }
        if (!mono) {
            if (saturation != 0f) {
                val l = luma(); val k = 1 + saturation
                r = l + (r - l) * k; g = l + (g - l) * k; b = l + (b - l) * k
            }
            if (vibrance != 0f) {
                val spread = max(r, max(g, b)) - min(r, min(g, b))
                val k = 1 + vibrance * (1 - spread.coerceIn(0f, 1f))
                val l = luma()
                r = l + (r - l) * k; g = l + (g - l) * k; b = l + (b - l) * k
            }
        }
        if (!shadowTint.isZero || !highlightTint.isZero) {
            val l = luma().coerceIn(0f, 1f)
            val il = 1 - l
            r += shadowTint.x * il * il + highlightTint.x * l * l
            g += shadowTint.y * il * il + highlightTint.y * l * l
            b += shadowTint.z * il * il + highlightTint.z * l * l
        }
        if (fade != 0f) {
            val k = 1 - 0.22f * fade; val add = 0.13f * fade
            r = r * k + add; g = g * k + add; b = b * k + add
        }
        return floatArrayOf(r.coerceIn(0f, 1f), g.coerceIn(0f, 1f), b.coerceIn(0f, 1f))
    }

    companion object {
        /** GLSL：`vec3 <p>_map(vec3 c)` 和它要的 uniform 声明。输入会被夹到 0...1（和 iOS 的 3D LUT 一样）。 */
        fun glsl(p: String = "cp"): String = """
uniform vec4 ${p}_a;
uniform vec4 ${p}_b;
uniform vec4 ${p}_c;
uniform vec3 ${p}_w;
uniform vec3 ${p}_st;
uniform vec3 ${p}_ht;
vec3 ${p}_map(vec3 c) {
    const vec3 W = vec3(0.299, 0.587, 0.114);
    vec4 A = ${p}_a; vec4 B = ${p}_b; vec4 C = ${p}_c;
    c = clamp(c, 0.0, 1.0);
    if (A.x != 0.0) c *= pow(2.0, A.x * 0.9);
    if (B.w != 0.0 || C.x != 0.0) c *= vec3(1.0 + 0.16 * B.w + 0.04 * C.x, 1.0 - 0.10 * C.x, 1.0 - 0.16 * B.w + 0.04 * C.x);
    c = clamp(c, 0.0, 1.0);
    bool mono = C.z > 0.5;
    if (mono) c = vec3(clamp(dot(c, ${p}_w), 0.0, 1.0));
    if (A.y != 0.0) c = pow(c, vec3(pow(2.0, -A.y * 0.8)));
    if (A.z > 0.0) {
        vec3 lo = c * c * 2.0;
        vec3 inv = 1.0 - c;
        vec3 hi = 1.0 - inv * inv * 2.0;
        vec3 s = mix(lo, hi, step(0.5, c));
        c = c + (s - c) * (A.z * 0.75);
    } else if (A.z < 0.0) {
        c = 0.5 + (c - 0.5) * (1.0 + A.z * 0.6);
    }
    if (A.w != 0.0 || B.x != 0.0) {
        float l = max(dot(c, W), 0.0001);
        float il = 1.0 - l;
        float ws = 9.48 * l * il * il * il;
        float wh = 9.48 * il * l * l * l;
        c *= (l + 0.1 * B.x * ws + 0.1 * A.w * wh) / l;
    }
    if (!mono) {
        if (B.y != 0.0) { float l = dot(c, W); c = l + (c - l) * (1.0 + B.y); }
        if (B.z != 0.0) {
            float spread = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
            float k = B.z * (1.0 - clamp(spread, 0.0, 1.0));
            float l = dot(c, W);
            c = l + (c - l) * (1.0 + k);
        }
    }
    if (any(notEqual(${p}_st, vec3(0.0))) || any(notEqual(${p}_ht, vec3(0.0)))) {
        float l = clamp(dot(c, W), 0.0, 1.0);
        float il = 1.0 - l;
        c += ${p}_st * (il * il) + ${p}_ht * (l * l);
    }
    if (C.y != 0.0) c = c * (1.0 - 0.22 * C.y) + vec3(0.13 * C.y);
    return clamp(c, 0.0, 1.0);
}
"""
    }
}
