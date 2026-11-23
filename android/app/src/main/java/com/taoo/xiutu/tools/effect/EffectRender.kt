package com.taoo.xiutu.tools.effect

import android.graphics.Bitmap
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * 特效的实现（照 iOS EffectRender 的 Core Image 做法）。
 *
 * Core Image 的混合、模糊、调色都是在线性光里算的（色调曲线除外，它在 sRGB 上），这里也一样：
 * 着色器里先把 sRGB 解码成线性，算完再编码回去。要模糊的中间层在缩小的浮点纹理上算（长边一般 900～1600），
 * 最后一遍在原尺寸上把原图和这些层合起来：大图上回放只多出一张原尺寸的输出纹理，不会占太多内存。
 * iOS 的坐标 y 朝上，这里 uv 原点在左上：位置相关的东西都换算过（y → H − y）。
 */
internal object EffectRender {
    fun render(kind: EffectKind, src: Bitmap, s: Float, v: EffectVariant, vi: Int, seed: Long, chaos: Float, mask: Bitmap?): Bitmap {
        val w = src.width
        val h = src.height
        // Canvas 画的叠加层先在调用线程上画好（不占 GPU 线程）。
        val overlay: Bitmap? = when (kind) {
            EffectKind.GOD_RAYS -> EffectDraw.overlay(w, h, seed, chaos) { c, W, H, rng, p -> EffectDraw.godRays(c, W, H, rng, p, vi == 0, v) }
            EffectKind.RAINBOW -> EffectDraw.overlay(w, h, seed, chaos) { c, W, H, rng, p -> EffectDraw.rainbow(c, W, H, rng, p) }
            EffectKind.BOKEH_LIGHT -> EffectDraw.overlay(w, h, seed, chaos) { c, W, H, rng, p -> EffectDraw.bokehSpots(c, W, H, rng, p, if (vi == 2) null else v) }
            EffectKind.LEAF_SHADOW -> EffectDraw.overlay(w, h, seed, chaos) { c, W, H, rng, p -> EffectDraw.leafPattern(c, W, H, rng, p) }
            EffectKind.BLINDS -> EffectDraw.overlay(w, h, seed, chaos) { c, W, H, _, p -> EffectDraw.blindsPattern(c, W, H, p) }
            else -> if (kind.category == EffectCategory.ATMOSPHERE) {
                EffectDraw.overlay(w, h, seed, chaos) { c, W, H, rng, p -> EffectDraw.particles(kind, c, W, H, rng, p) }
            } else null
        }
        return Gpu.run {
            val f = Fx(this, upload(src))
            val out = f.render(kind, s, v, vi, seed, chaos, mask, overlay) ?: return@run src
            read(out)
        }
    }

    /** 色调曲线（5 个点，x 均匀 0…1）做成 256×1 的查找表，自然三次样条插值。 */
    fun curveLUT(ys: FloatArray): Bitmap {
        val n = ys.size
        val xs = FloatArray(n) { it / (n - 1f) }
        // 自然样条的二阶导数
        val m = FloatArray(n)
        val hh = 1f / (n - 1)
        val a = FloatArray(n)
        val b = FloatArray(n)
        val c = FloatArray(n)
        val d = FloatArray(n)
        for (i in 1 until n - 1) {
            a[i] = hh; b[i] = 4 * hh; c[i] = hh
            d[i] = 6 * ((ys[i + 1] - ys[i]) / hh - (ys[i] - ys[i - 1]) / hh)
        }
        // 追赶法
        for (i in 2 until n - 1) {
            val k = a[i] / b[i - 1]
            b[i] -= k * c[i - 1]
            d[i] -= k * d[i - 1]
        }
        for (i in n - 2 downTo 1) m[i] = (d[i] - c[i] * m[i + 1]) / b[i]
        val px = IntArray(256) { k ->
            val x = k / 255f
            val i = min(n - 2, (x / hh).toInt())
            val t0 = xs[i + 1] - x
            val t1 = x - xs[i]
            val y = m[i] * t0 * t0 * t0 / (6 * hh) + m[i + 1] * t1 * t1 * t1 / (6 * hh) +
                (ys[i] / hh - m[i] * hh / 6) * t0 + (ys[i + 1] / hh - m[i + 1] * hh / 6) * t1
            val g = (y.coerceIn(0f, 1f) * 255f).roundToInt()
            (0xFF shl 24) or (g shl 16) or (g shl 8) or g
        }
        return Bitmap.createBitmap(px, 256, 1, Bitmap.Config.ARGB_8888)
    }

    fun srgbToLinear(c: Float): Float = if (c <= 0.04045f) c / 12.92f else ((c + 0.055f) / 1.055f).pow(2.4f)

    fun lin3(r: Float, g: Float, b: Float) = floatArrayOf(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
}

/** 一次渲染：原图 src 已经在 GPU 上。 */
private class Fx(val g: GpuScope, val src: Tex) {
    val W = src.width
    val H = src.height
    val dim = max(W, H).toFloat()
    private val works = HashMap<Int, Tex>()

    // MARK: 基础操作

    /** 缩到长边不超过 maxDim（只缩不放），每次最多缩一半，不起锯齿。 */
    fun shrink(t: Tex, maxDim: Float): Tex {
        var cur = t
        val long = max(t.width, t.height)
        if (long <= maxDim * 1.02f) return t
        val k = maxDim / long
        val tw = max(1, (t.width * k).roundToInt())
        val th = max(1, (t.height * k).roundToInt())
        while (cur.width / 2 >= tw && cur.height / 2 >= th && max(cur.width, cur.height) / 2 > maxDim) {
            cur = g.pass(Shaders.COPY, mapOf("src" to cur), emptyMap(), max(1, cur.width / 2), max(1, cur.height / 2), t.float)
        }
        return g.pass(Shaders.COPY, mapOf("src" to cur), emptyMap(), tw, th, t.float)
    }

    /** 原图的线性浮点副本，长边不超过 maxDim。 */
    fun work(maxDim: Float): Tex {
        val key = maxDim.roundToInt()
        return works.getOrPut(key) {
            val small = shrink(src, maxDim)
            g.passFloat(FxShaders.TO_LIN, mapOf("src" to small), emptyMap(), small.width, small.height)
        }
    }

    /** 任意 sRGB 纹理（可带透明）→ 线性预乘浮点，长边不超过 maxDim。 */
    fun linear(t: Tex, maxDim: Float): Tex {
        val small = shrink(t, maxDim)
        return g.passFloat(FxShaders.TO_LIN, mapOf("src" to small), emptyMap(), small.width, small.height)
    }

    /** 高斯模糊。sigma 是这张纹理上的像素（Core Image 的半径就是 sigma）。 */
    fun blur(t: Tex, sigma: Float): Tex = if (sigma < 0.3f) t else g.blur(t, sigma * 2.5f)

    /** 纹理相对原图的比例。 */
    fun scaleOf(t: Tex) = max(t.width, t.height) / dim

    /**
     * iOS 的 blurLow：大半径时先缩小再模糊。r 是原图像素。
     * 这里工作尺寸最多 2048（再大就和原尺寸模糊看不出差别了），返回线性浮点纹理。
     */
    fun blurLow(r: Float): Tex {
        val k = if (r > 6 && dim > 900) max(900 / dim, min(1f, 8 / r)) else 1f
        val t = work(min(dim * k, 2048f))
        return blur(t, r * scaleOf(t))
    }

    /** 同上，模糊的是一张自己的线性纹理。 */
    fun blurLowOf(t: Tex, r: Float): Tex {
        val k = if (r > 6 && dim > 900) max(900 / dim, min(1f, 8 / r)) else 1f
        val small = shrink(t, min(dim * k, 2048f))
        return blur(small, r * scaleOf(small))
    }

    /** 蒙版：上传，羽化 r（原图像素）。蒙版本身不做色彩转换（和 iOS 一样按原始数值用）。 */
    fun feather(mask: Tex, r: Float): Tex = blur(mask, r * max(mask.width, mask.height) / dim)

    /** 方向模糊（Core Image 的 CIMotionBlur：沿一个方向的高斯，sigma = 半径）。 */
    fun motion(t: Tex, sigma: Float, vertical: Boolean): Tex {
        if (sigma < 0.3f) return t
        val step = sigma * 3f / 48f
        val dir = if (vertical) floatArrayOf(0f, step) else floatArrayOf(step, 0f)
        return g.pass(FxShaders.MOTION, mapOf("src" to t), mapOf("dir" to dir, "sigma" to sigma), t.width, t.height, t.float)
    }

    /** 圆盘模糊（CIBokehBlur，柔边）。r 是这张纹理上的像素。 */
    fun disc(t: Tex, r: Float): Tex {
        var input = t
        var rr = r
        // 半径太大时先缩小，采样点不至于太稀
        while (rr > 18f && input.width > 64 && input.height > 64) {
            input = g.pass(Shaders.COPY, mapOf("src" to input), emptyMap(), input.width / 2, input.height / 2, t.float)
            rr /= 2
        }
        if (rr < 0.5f) return input
        val d = g.pass(FxShaders.DISC, mapOf("src" to input), mapOf("radius" to rr), input.width, input.height, t.float)
        // 采样点之间的缝抹平
        return blur(d, rr * 0.12f)
    }

    private fun finish(frag: String, inputs: Map<String, Tex>, uniforms: Map<String, Any>): Tex =
        g.pass(frag, mapOf("src" to src) + inputs, uniforms, W, H)

    private fun curve(vararg ys: Float): Tex = g.upload(EffectRender.curveLUT(ys))

    // MARK: 各个效果

    fun render(kind: EffectKind, s: Float, v: EffectVariant, vi: Int, seed: Long, chaos: Float, maskBmp: Bitmap?, overlay: Bitmap?): Tex? {
        val mask = maskBmp?.let { g.upload(it) }
        val k = "s" to s
        return when (kind) {
            // 光
            EffectKind.BLACK_MIST -> {
                val hiSrc = work(min(dim, 1200f))
                val hi = g.passFloat(FxShaders.HIGHLIGHTS, mapOf("src" to hiSrc), mapOf("t" to 0.55f), hiSrc.width, hiSrc.height)
                val sc = scaleOf(hi)
                val wide = blur(hi, dim * 0.022f * sc)
                val near = blur(hi, dim * 0.006f * sc)
                finish(FxShaders.BLACK_MIST, mapOf("wide" to wide, "near" to near,
                    "curve" to curve(0.025f * s, 0.25f + 0.01f * s, 0.5f, 0.75f - 0.02f * s, 1 - 0.03f * s)), mapOf(k))
            }
            EffectKind.WHITE_MIST -> finish(FxShaders.WHITE_MIST, mapOf("glow" to blurLow(dim * 0.018f),
                "curve" to curve(0.07f * s, 0.27f + 0.03f * s, 0.5f + 0.02f * s, 0.75f, 1f)), mapOf(k))
            EffectKind.SOFT_FOCUS -> finish(FxShaders.SOFT_FOCUS, mapOf("glow" to blurLow(dim * 0.012f)), mapOf(k))
            EffectKind.RIM_LIGHT -> {
                mask ?: return null
                rimLight(mask, s, v)
            }
            EffectKind.SUN_FLARE -> sunFlare(s, v)
            EffectKind.STARBURST -> {
                val points = if (vi == 1) 6 else if (vi == 2) 8 else 4
                val small = g.read(shrink(src, 72f))
                val stars = EffectDraw.stars(small, W, H, points, seed, chaos) ?: return null
                finish(FxShaders.SCREEN_LAYER, mapOf("layer" to g.upload(stars)), mapOf("k" to s))
            }
            EffectKind.GOD_RAYS -> {
                val layer = linear(g.upload(overlay ?: return null), EffectDraw.MAX_SIDE.toFloat())
                finish(FxShaders.SCREEN_LIN, mapOf("layer" to blurLowOf(layer, dim * 0.012f)), mapOf("k" to 1.1f * s))
            }
            EffectKind.LIGHT_LEAK -> {
                val side = EffectRender.lin3(v.r * 0.95f, v.g * 0.95f, v.b * 0.95f)
                val corner = EffectRender.lin3(min(1f, v.r * 0.6f + 0.4f), min(1f, v.g * 0.5f + 0.35f), v.b * 0.5f + 0.1f)
                finish(FxShaders.LIGHT_LEAK, emptyMap(), mapOf(k, "sideColor" to side, "cornerColor" to corner, "dim" to dim))
            }
            EffectKind.RAINBOW -> {
                val layer = linear(g.upload(overlay ?: return null), EffectDraw.MAX_SIDE.toFloat())
                finish(FxShaders.SCREEN_LIN, mapOf("layer" to blurLowOf(layer, dim * 0.022f)), mapOf("k" to 0.75f * s))
            }
            EffectKind.BOKEH_LIGHT -> {
                val layer = linear(g.upload(overlay ?: return null), EffectDraw.MAX_SIDE.toFloat())
                finish(FxShaders.SCREEN_LIN, mapOf("layer" to blur(layer, dim * 0.002f * scaleOf(layer))), mapOf("k" to s))
            }
            EffectKind.LEAF_SHADOW, EffectKind.BLINDS -> {
                val pattern = linear(g.upload(overlay ?: return null), EffectDraw.MAX_SIDE.toFloat())
                val r = dim * (if (kind == EffectKind.LEAF_SHADOW) 0.0045f else 0.006f)
                finish(FxShaders.DAPPLE, mapOf("pattern" to blur(pattern, r * scaleOf(pattern))), mapOf(k))
            }

            // 模糊
            EffectKind.BG_BLUR -> {
                mask ?: return null
                val blurred = blurLow(dim * (0.004f + 0.03f * s))
                finish(FxShaders.KEEP_SUBJECT, mapOf("back" to blurred, "mask" to feather(mask, dim * 0.002f)), mapOf("sat" to 1f))
            }
            EffectKind.BOKEH -> {
                mask ?: return null
                val t = work(min(dim, 1200f))
                val back = disc(t, max(t.width, t.height) * (0.006f + 0.03f * s))
                finish(FxShaders.KEEP_SUBJECT, mapOf("back" to back, "mask" to feather(mask, dim * 0.002f)), mapOf("sat" to 1.06f))
            }
            EffectKind.DEFOCUS -> {
                val t = work(min(dim, 1200f))
                finish(FxShaders.SHOW_LIN, mapOf("layer" to disc(t, max(t.width, t.height) * (0.003f + 0.022f * s))), emptyMap())
            }
            EffectKind.MOTION_BLUR -> {
                val t = work(min(dim, 1600f))
                val moving = motion(t, max(t.width, t.height) * (0.006f + 0.04f * s), vi == 1)
                if (mask == null) finish(FxShaders.SHOW_LIN, mapOf("layer" to moving), emptyMap())
                else finish(FxShaders.KEEP_SUBJECT, mapOf("back" to moving, "mask" to feather(mask, dim * 0.002f)), mapOf("sat" to 1f))
            }
            EffectKind.ZOOM_BLUR -> {
                val t = work(min(dim, 1600f))
                val d = max(t.width, t.height).toFloat()
                val amount = d * (0.01f + 0.06f * s)
                // Core Image 的放射模糊：每个点往中心方向取样，最远缩到 e^(−0.0208·amount)（实测）
                val zoomed = g.pass(FxShaders.ZOOM, mapOf("src" to t), mapOf("fmin" to exp(-0.0208f * amount)), t.width, t.height, true)
                finish(FxShaders.ZOOM_FINAL, mapOf("back" to zoomed, "mask" to (mask?.let { feather(it, dim * 0.002f) } ?: zoomed)),
                    mapOf("dim" to dim, "hasMask" to (mask != null)))
            }
            EffectKind.GHOST -> {
                val step = dim * (0.012f + 0.03f * s)
                if (mask != null) finish(FxShaders.GHOST_SUBJECT, mapOf("mask" to feather(mask, dim * 0.002f)), mapOf(k, "stepPx" to step))
                else finish(FxShaders.GHOST, emptyMap(), mapOf(k, "stepPx" to step))
            }
            EffectKind.LONG_EXPOSURE -> {
                val t = work(min(dim, 1600f))
                val streak = motion(t, max(t.width, t.height) * 0.07f, false)
                finish(FxShaders.LONG_EXPOSURE, mapOf("streak" to streak, "mask" to (mask?.let { feather(it, dim * 0.004f) } ?: streak)),
                    mapOf(k, "hasMask" to (mask != null)))
            }
            EffectKind.GAUSSIAN -> finish(FxShaders.SHOW_LIN, mapOf("layer" to blurLow(dim * (0.002f + 0.03f * s))), emptyMap())

            // 复古
            EffectKind.VHS -> finish(FxShaders.VHS, mapOf("curve" to curve(0.06f, 0.28f, 0.52f, 0.76f, 0.96f)),
                mapOf(k, "dx" to dim * 0.004f * (0.4f + s), "sigma" to dim * 0.0012f, "period" to H / 260f))
            EffectKind.LOW_PIXEL -> finish(FxShaders.PIXELLATE, emptyMap(), mapOf("cell" to max(2f, dim * (0.004f + 0.02f * s))))
            EffectKind.LED -> {
                val cell = dim / 90f
                val t = work(min(dim, 900f))
                val glow = blur(t, dim * 0.012f * scaleOf(t))
                finish(FxShaders.LED, mapOf("glow" to glow), mapOf(k, "cell" to cell, "aa" to max(1f, dim / EffectDraw.MAX_SIDE)))
            }
            EffectKind.NEON -> {
                val t = work(min(dim, 1400f))
                val d = max(t.width, t.height).toFloat()
                val line = g.passFloat(FxShaders.NEON_LINE, mapOf("soft" to blur(t, d * 0.001f), "wide" to blur(t, d * 0.004f)),
                    mapOf("color" to floatArrayOf(v.r * 1.4f, v.g * 1.4f, v.b * 1.4f)), t.width, t.height)
                finish(FxShaders.NEON, mapOf("line" to line, "glow" to blurLowOf(line, dim * 0.008f)), mapOf(k))
            }
            EffectKind.GLITCH -> glitch(s, seed, chaos)
            EffectKind.CRT -> {
                val t = work(min(dim, 900f))
                val glow = blur(t, dim * 0.012f * scaleOf(t))
                finish(FxShaders.CRT, mapOf("glow" to glow), mapOf(k, "dim" to dim, "dx" to dim * 0.0018f, "period" to H / 220f))
            }
            EffectKind.VAPORWAVE -> finish(FxShaders.VAPORWAVE, emptyMap(), mapOf(k,
                "c0" to EffectRender.lin3(0.16f, 0.03f, 0.36f), "c1" to EffectRender.lin3(1f, 0.62f, 0.86f)))
            EffectKind.HALFTONE -> finish(FxShaders.HALFTONE, emptyMap(), mapOf(k, "cell" to max(3f, dim / 130f)))
            EffectKind.LOFI -> {
                val soft = blurLow(dim * 0.0012f)
                finish(FxShaders.LOFI, mapOf("soft" to soft, "curve" to curve(0.08f, 0.3f, 0.52f, 0.74f, 0.92f)), mapOf(k))
            }

            // 氛围
            else -> finish(FxShaders.PARTICLES, mapOf("layer" to g.upload(overlay ?: return null)), mapOf("k" to min(1f, 0.25f + 0.9f * s)))
        }
    }

    // MARK: 轮廓光

    private fun rimLight(mask: Tex, s: Float, v: EffectVariant): Tex {
        // 光的形状只跟蒙版有关，又很柔，在蒙版自己的尺寸上算（不超过 1400）。
        val m = shrink(mask, 1400f)
        val d = max(m.width, m.height).toFloat()
        val r = max(1f, d * 0.006f)
        val e1 = g.pass(FxShaders.ERODE, mapOf("src" to m), mapOf("dir" to floatArrayOf(1f, 0f), "radius" to r), m.width, m.height)
        val eroded = g.pass(FxShaders.ERODE, mapOf("src" to e1), mapOf("dir" to floatArrayOf(0f, 1f), "radius" to r), m.width, m.height)
        // 边缘内侧的一圈亮带。
        val band = g.passFloat(FxShaders.DIFF, mapOf("a" to m, "b" to eroded), emptyMap(), m.width, m.height)
        val inner = blur(band, d * 0.003f)
        val halo = blur(m, d * 0.02f)
        val light = g.passFloat(FxShaders.RIM_SHAPE, mapOf("mask" to m, "inner" to inner, "halo" to halo), emptyMap(), m.width, m.height)
        return finish(FxShaders.RIM_LIGHT, mapOf("light" to light, "mask" to feather(mask, dim * 0.003f)),
            mapOf("s" to s, "color" to floatArrayOf(v.r * 1.25f * s, v.g * 1.25f * s, v.b * 1.25f * s)))
    }

    // MARK: 逆光光晕

    private fun sunFlare(s: Float, c: EffectVariant): Tex {
        // iOS 的太阳在 (0.84, 0.86)，y 朝上；这里换成左上原点。
        val sunX = W * 0.84f
        val sunY = H * (1 - 0.86f)
        val midX = W / 2f
        val midY = H / 2f
        val xs = ArrayList<Float>()
        val ys = ArrayList<Float>()
        val r0 = ArrayList<Float>()
        val r1 = ArrayList<Float>()
        val cr = ArrayList<Float>()
        val cg = ArrayList<Float>()
        val cb = ArrayList<Float>()
        fun disc(x: Float, y: Float, a0: Float, a1: Float, r: Float, g: Float, b: Float, a: Float) {
            xs += x; ys += y; r0 += a0; r1 += a1
            val l = EffectRender.lin3((r * a).coerceIn(0f, 1f), (g * a).coerceIn(0f, 1f), (b * a).coerceIn(0f, 1f))
            cr += l[0]; cg += l[1]; cb += l[2]
        }
        // 大片暖光 + 太阳本身。
        disc(sunX, sunY, 0f, dim * 0.75f, c.r, c.g, c.b, 0.75f * s)
        disc(sunX, sunY, dim * 0.015f, dim * 0.13f, 1f, 0.98f, 0.92f, 0.95f * s)
        // 镜头里的鬼影：沿着太阳到画面中心的连线。
        val ghosts = listOf(
            floatArrayOf(0.55f, 0.025f, 0.6f, 1f, 0.6f, 0.22f), floatArrayOf(0.95f, 0.06f, 0.75f, 0.6f, 1f, 0.16f),
            floatArrayOf(1.3f, 0.018f, 1f, 0.7f, 0.4f, 0.28f), floatArrayOf(1.65f, 0.1f, 0.5f, 0.8f, 1f, 0.12f),
        )
        for (gh in ghosts) {
            val t = gh[0]
            disc(sunX + (midX - sunX) * t, sunY + (midY - sunY) * t, dim * gh[1] * 0.6f, dim * gh[1], gh[2], gh[3], gh[4], gh[5] * s)
        }
        return finish(FxShaders.SUN_FLARE, emptyMap(), mapOf("dx" to xs, "dy" to ys, "r0" to r0, "r1" to r1, "cr" to cr, "cg" to cg, "cb" to cb))
    }

    // MARK: 故障

    private fun glitch(s: Float, seed: Long, chaos: Float): Tex {
        val rng = EffectRNG(seed + 99, chaos)
        val y0 = ArrayList<Float>()
        val y1 = ArrayList<Float>()
        val shift = ArrayList<Float>()
        repeat(9) {
            val h = H * rng.range(0.008, 0.06).toFloat()
            val y = H * rng.next().toFloat()
            val dx = dim * rng.range(-0.06, 0.06).toFloat() * s
            // iOS 的条带 y 朝上：[y, y+h] → 这里的行 [H−y−h, H−y]
            y0 += H - y - h
            y1 += H - y
            shift += dx
        }
        // 补到 10 个，避免 9 个元素被当成矩阵上传
        y0 += -1f; y1 += -1f; shift += 0f
        return finish(FxShaders.GLITCH, emptyMap(), mapOf("s" to s, "split" to dim * 0.008f * (0.3f + s), "by0" to y0, "by1" to y1, "bdx" to shift))
    }
}

/** 特效用到的着色器。 */
private object FxShaders {
    /** 公共函数：sRGB ↔ 线性、滤色、饱和度、对比度、色调曲线。 */
    private const val PRE = Shaders.HEADER + Shaders.COLOR_FUNCS + """
uniform sampler2D src;
// 去预乘后的线性色
vec3 linU(vec4 c) { return c.a > 0.0 ? srgbToLinear(clamp(c.rgb / c.a, 0.0, 1.0)) : vec3(0.0); }
// 预乘的线性色
vec4 linP(vec4 c) { return vec4(linU(c) * c.a, c.a); }
vec4 encU(vec3 c, float a) { return vec4(linearToSrgb(clamp(c, 0.0, 1.0)) * a, a); }
vec3 screen(vec3 a, vec3 b) { return a + b - a * b; }
vec3 satur(vec3 c, float s) { return mix(vec3(luma(c)), c, s); }
vec3 contr(vec3 c, float k) { return (c - 0.5) * k + 0.5; }
// 线性像素坐标（原点左上）
vec2 P() { return uv * size; }
vec4 at(vec2 p) { return texture(src, p / size); }
"""

    private const val CURVE = """
uniform sampler2D curve;
float cv(float x) { return texture(curve, vec2(clamp(x, 0.0, 1.0) * 255.0 / 256.0 + 0.5 / 256.0, 0.5)).r; }
// 色调曲线在 sRGB 上做（和 Core Image 一样）
vec3 tone(vec3 c) { vec3 e = linearToSrgb(clamp(c, 0.0, 1.0)); return srgbToLinear(vec3(cv(e.r), cv(e.g), cv(e.b))); }
"""

    /** 扫描线：period 像素一个周期，darkness 是最暗处的不透明度。y 用 iOS 的朝上坐标。 */
    private const val SCAN = """
float scan(float y, float period, float darkness) {
    if (period < 1.5) return 1.0;
    float f = clamp(cos(6.2831853 * (y - 0.22 * period) / period) * 0.8333 + 0.5, 0.0, 1.0);
    return 1.0 - darkness * (1.0 - f);
}
"""

    const val TO_LIN = PRE + """
void main() { o = linP(texture(src, uv)); }
"""

    const val HIGHLIGHTS = PRE + """
uniform float t;
void main() { vec4 c = texture(src, uv); o = vec4(clamp((c.rgb - t) / (1.0 - t), 0.0, 1.0), 1.0); }
"""

    /** 沿 dir 方向的一维高斯，两边各 48 个点。 */
    const val MOTION = PRE + """
uniform vec2 dir;
uniform float sigma;
void main() {
    vec2 px = dir / size;
    float stp = length(dir);
    vec4 acc = texture(src, uv);
    float wsum = 1.0;
    for (int i = 1; i <= 48; i++) {
        float d = float(i) * stp;
        float w = exp(-d * d / (2.0 * sigma * sigma));
        acc += (texture(src, uv + px * float(i)) + texture(src, uv - px * float(i))) * w;
        wsum += 2.0 * w;
    }
    o = acc / wsum;
}
"""

    /** 往画面中心方向取样（缩放比例从 1 到 fmin，按对数均匀）。 */
    const val ZOOM = PRE + """
uniform float fmin;
void main() {
    vec2 c = vec2(0.5);
    vec4 acc = vec4(0.0);
    float lf = log(fmin);
    for (int i = 0; i < 64; i++) {
        float f = exp(lf * float(i) / 63.0);
        acc += texture(src, c + (uv - c) * f);
    }
    o = acc / 64.0;
}
"""

    /** 圆盘模糊：黄金角螺旋上取 96 个点，边缘柔一点。 */
    const val DISC = PRE + """
uniform float radius;
void main() {
    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 96; i++) {
        float r = sqrt((float(i) + 0.5) / 96.0);
        float a = float(i) * 2.39996323;
        float w = 1.0 - 0.5 * smoothstep(0.6, 1.0, r);
        acc += texture(src, uv + vec2(cos(a), sin(a)) * r * radius / size) * w;
        wsum += w;
    }
    o = acc / wsum;
}
"""

    /** 一维最小值（腐蚀），横竖各做一遍。 */
    const val ERODE = PRE + """
uniform vec2 dir;
uniform float radius;
void main() {
    float m = texture(src, uv).r;
    int n = int(ceil(radius));
    for (int i = 1; i <= 24; i++) {
        if (i > n) break;
        vec2 d = dir * float(i) / size;
        m = min(m, min(texture(src, uv + d).r, texture(src, uv - d).r));
    }
    o = vec4(vec3(m), 1.0);
}
"""

    const val DIFF = PRE + """
uniform sampler2D a;
uniform sampler2D b;
void main() { o = vec4(vec3(abs(texture(a, uv).r - texture(b, uv).r)), 1.0); }
"""

    /** 轮廓光的形状：内侧亮带 + 外侧光晕，上面亮下面弱。 */
    const val RIM_SHAPE = PRE + """
uniform sampler2D mask;
uniform sampler2D inner;
uniform sampler2D halo;
void main() {
    float m = texture(mask, uv).r;
    float sum = 1.5 * texture(inner, uv).r * m + 0.85 * texture(halo, uv).r * (1.0 - m);
    float grad = mix(1.0, 0.171, uv.y);
    o = vec4(vec3(sum * grad), 1.0);
}
"""

    const val RIM_LIGHT = PRE + """
uniform sampler2D light;
uniform sampler2D mask;
uniform float s;
uniform vec3 color;
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    vec3 tinted = clamp(texture(light, uv).r * color, 0.0, 1.0);
    // 背景压暗一点，边缘光更跳。
    vec3 darker = b * exp2(-0.55 * s);
    vec3 base = mix(darker, b, texture(mask, uv).r);
    o = encU(screen(tinted, base), c.a);
}
"""

    const val BLACK_MIST = PRE + CURVE + """
uniform sampler2D wide;
uniform sampler2D near;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 glow = 0.95 * texture(wide, uv).rgb + 0.55 * texture(near, uv).rgb;
    vec3 r = screen(0.75 * s * glow, linU(c));
    o = encU(tone(r), c.a);
}
"""

    const val WHITE_MIST = PRE + CURVE + """
uniform sampler2D glow;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 r = screen(0.55 * s * texture(glow, uv).rgb, linU(c));
    r = satur(tone(r), 1.0 - 0.1 * s);
    o = encU(r, c.a);
}
"""

    const val SOFT_FOCUS = PRE + """
uniform sampler2D glow;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    vec3 soft = max(texture(glow, uv).rgb, b);
    o = encU(mix(b, soft, 0.85 * s), c.a);
}
"""

    /** 线性预乘的叠加层滤色上去（乘 k）。 */
    const val SCREEN_LIN = PRE + """
uniform sampler2D layer;
uniform float k;
void main() {
    vec4 c = texture(src, uv);
    o = encU(screen(k * texture(layer, uv).rgb, linU(c)), c.a);
}
"""

    /** sRGB 叠加层滤色上去（乘 k）。 */
    const val SCREEN_LAYER = PRE + """
uniform sampler2D layer;
uniform float k;
void main() {
    vec4 c = texture(src, uv);
    o = encU(screen(k * linP(texture(layer, uv)).rgb, linU(c)), c.a);
}
"""

    /** 线性纹理直接显示（模糊类）。 */
    const val SHOW_LIN = PRE + """
uniform sampler2D layer;
void main() {
    vec4 c = texture(src, uv);
    o = encU(texture(layer, uv).rgb, c.a);
}
"""

    /** 主体（蒙版白）保持原图，其余用 back。 */
    const val KEEP_SUBJECT = PRE + """
uniform sampler2D back;
uniform sampler2D mask;
uniform float sat;
void main() {
    vec4 c = texture(src, uv);
    vec3 bk = texture(back, uv).rgb;
    bk = satur(bk, sat);
    o = encU(mix(bk, linU(c), texture(mask, uv).r), c.a);
}
"""

    const val LIGHT_LEAK = PRE + """
uniform vec3 sideColor;
uniform vec3 cornerColor;
uniform float dim;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec2 p = P();
    vec3 side = mix(sideColor, vec3(0.0), clamp(p.x / (size.x * 0.48), 0.0, 1.0));
    vec2 cc = vec2(size.x * 0.95, size.y * 0.03);
    vec3 corner = mix(cornerColor, vec3(0.0), clamp(length(p - cc) / (dim * 0.55), 0.0, 1.0));
    vec3 leak = side + 0.8 * corner;
    o = encU(screen(s * leak, linU(c)), c.a);
}
"""

    const val SUN_FLARE = PRE + """
uniform float dx[6];
uniform float dy[6];
uniform float r0[6];
uniform float r1[6];
uniform float cr[6];
uniform float cg[6];
uniform float cb[6];
void main() {
    vec4 c = texture(src, uv);
    vec3 r = linU(c);
    vec2 p = P();
    for (int i = 0; i < 6; i++) {
        float t = clamp((length(p - vec2(dx[i], dy[i])) - r0[i]) / max(r1[i] - r0[i], 0.001), 0.0, 1.0);
        r = screen(vec3(cr[i], cg[i], cb[i]) * (1.0 - t), r);
    }
    o = encU(r, c.a);
}
"""

    /** 树影 / 百叶窗：亮处提亮偏暖，暗处压暗偏冷。 */
    const val DAPPLE = PRE + """
uniform sampler2D pattern;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    vec3 lit = b * exp2(0.45) * vec3(1.069, 0.983, 0.839);
    vec3 shade = b * exp2(-1.7) * vec3(0.950, 1.0, 1.087);
    vec3 lighting = mix(shade, lit, texture(pattern, uv).r);
    o = encU(mix(b, lighting, min(1.0, 1.05 * s)), c.a);
}
"""

    const val ZOOM_FINAL = PRE + """
uniform sampler2D back;
uniform sampler2D mask;
uniform float dim;
uniform bool hasMask;
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    // 中心保持清楚。
    float t = clamp((length(P() - size * 0.5) - dim * 0.08) / (dim * 0.34), 0.0, 1.0);
    vec3 r = mix(texture(back, uv).rgb, b, 1.0 - t);
    if (hasMask) r = mix(r, b, texture(mask, uv).r);
    o = encU(r, c.a);
}
"""

    /** 拖影（有主体）：主体的几个残影往后排，越远越淡。 */
    const val GHOST_SUBJECT = PRE + """
uniform sampler2D mask;
uniform float stepPx;
uniform float s;
vec4 subject(vec2 p) {
    if (p.x < 0.0 || p.x > size.x) return vec4(0.0);
    vec2 q = p / size;
    return linP(texture(src, q)) * texture(mask, q).r;
}
void main() {
    vec4 c = texture(src, uv);
    vec4 r = linP(c);
    vec2 p = P();
    for (int k = 4; k >= 1; k--) {
        float a = (0.55 - 0.11 * float(k)) * s;
        // Core Image 的 CIColorMatrix 在去预乘的颜色上乘，再预乘回去：颜色实际乘了 a²
        vec4 sub = subject(p + vec2(stepPx * float(k), 0.0));
        vec4 copy = vec4(sub.rgb * a * a, sub.a * a);
        r = copy + r * (1.0 - copy.a);
    }
    vec4 top = subject(p);
    r = top + r * (1.0 - top.a);
    o = encU(r.rgb / max(r.a, 0.0001), r.a);
}
"""

    /** 拖影（整张）：往右错开几份叠上去。 */
    const val GHOST = PRE + """
uniform float stepPx;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    vec3 r = b;
    vec2 p = P();
    for (int k = 1; k <= 4; k++) {
        vec3 shifted = linU(at(vec2(min(p.x + stepPx * float(k), size.x - 0.5), p.y)));
        r = mix(r, shifted, (0.32 - 0.06 * float(k)) * s);
    }
    o = encU(mix(r, b, 0.35), c.a);
}
"""

    const val LONG_EXPOSURE = PRE + """
uniform sampler2D streak;
uniform sampler2D mask;
uniform bool hasMask;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    vec3 dreamy = max(texture(streak, uv).rgb, b);
    vec3 r = mix(b, dreamy, 0.75 * s);
    if (hasMask) r = mix(r, b, 0.75 * texture(mask, uv).r);
    o = encU(r, c.a);
}
"""

    /** 录像带：RGB 错位 + 一点横向拖尾 + 褪色 + 扫描线。 */
    const val VHS = PRE + CURVE + SCAN + """
uniform float dx;
uniform float sigma;
uniform float period;
uniform float s;
vec3 split(vec2 p) {
    return vec3(linU(at(p - vec2(dx, 0.0))).r, linU(at(p)).g, linU(at(p + vec2(dx, 0.0))).b);
}
void main() {
    vec4 c = texture(src, uv);
    vec2 p = P();
    vec3 acc = split(p);
    float wsum = 1.0;
    if (sigma > 0.3) {
        float st = sigma * 3.0 / 8.0;
        for (int i = 1; i <= 8; i++) {
            float d = float(i) * st;
            float w = exp(-d * d / (2.0 * sigma * sigma));
            acc += (split(p + vec2(d, 0.0)) + split(p - vec2(d, 0.0))) * w;
            wsum += 2.0 * w;
        }
    }
    vec3 r = acc / wsum;
    r = contr(satur(r, 0.82), 0.92);
    r = tone(r);
    r *= scan(size.y - p.y, period, 0.22);
    o = encU(mix(linU(c), r, s), c.a);
}
"""

    /** 低像素：取每格中心的颜色（网格从 iOS 的左下角开始）。 */
    const val PIXELLATE = PRE + """
uniform float cell;
void main() {
    vec2 p = P();
    vec2 q = vec2(p.x, size.y - p.y);
    vec2 cc = (floor(q / cell) + 0.5) * cell;
    o = at(clamp(vec2(cc.x, size.y - cc.y), vec2(0.5), size - 0.5));
}
"""

    /** 电子屏：大像素 + 圆点阵 + 一点辉光。 */
    const val LED = PRE + """
uniform sampler2D glow;
uniform float cell;
uniform float aa;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec2 p = P();
    vec2 q = vec2(p.x, size.y - p.y);
    // 像素块：网格错开半格（和 iOS 一样）
    vec2 cc = (floor((q - cell * 0.5) / cell) + 1.0) * cell;
    vec3 pix = satur(linU(at(clamp(vec2(cc.x, size.y - cc.y), vec2(0.5), size - 0.5))), 1.25);
    // 圆点：中心在半格处，半径 0.4 格
    vec2 dc = floor(q / cell) * cell + cell * 0.5;
    float dt = 1.0 - smoothstep(cell * 0.4 - aa * 0.5, cell * 0.4 + aa * 0.5, length(q - dc));
    vec3 x = max(pix * dt, 0.0);
    // 辉光：模糊后点阵的平均覆盖率约 0.503
    vec3 bl = 0.503 * satur(texture(glow, uv).rgb, 1.25);
    vec3 r = max(x, mix(x, bl, 0.6));
    o = encU(mix(linU(c), r, s), c.a);
}
"""

    /** 霓虹的线：细模糊和粗模糊之差的亮度，拉强、上色。 */
    const val NEON_LINE = PRE + """
uniform sampler2D soft;
uniform sampler2D wide;
uniform vec3 color;
void main() {
    float raw = luma(abs(texture(soft, uv).rgb - texture(wide, uv).rgb));
    float e = clamp(1.6 * clamp((raw - 0.03) / 0.97, 0.0, 1.0), 0.0, 1.0);
    o = vec4(clamp(e * color, 0.0, 1.0), 1.0);
}
"""

    const val NEON = PRE + """
uniform sampler2D line;
uniform sampler2D glow;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    vec3 g = texture(line, uv).rgb + 2.2 * texture(glow, uv).rgb;
    vec3 dark = satur(b * exp2(-1.6), 0.6);
    o = encU(mix(b, screen(g, dark), s), c.a);
}
"""

    /** 故障：RGB 错位 + 9 条横向错开的条带（后面的盖住前面的）。 */
    const val GLITCH = PRE + """
uniform float split;
uniform float by0[10];
uniform float by1[10];
uniform float bdx[10];
uniform float s;
vec3 rgbAt(vec2 p) {
    p.x = clamp(p.x, 0.5, size.x - 0.5);
    return vec3(linU(at(p - vec2(split, 0.0))).r, linU(at(p)).g, linU(at(p + vec2(split, 0.0))).b);
}
void main() {
    vec4 c = texture(src, uv);
    vec2 p = P();
    float shift = 0.0;
    for (int i = 0; i < 10; i++) {
        if (p.y >= by0[i] && p.y < by1[i]) shift = bdx[i];
    }
    vec3 r = rgbAt(p - vec2(shift, 0.0));
    o = encU(mix(linU(c), r, min(1.0, 0.4 + s)), c.a);
}
"""

    /** 老电视：鼓起来的屏幕 + RGB 错位 + 扫描线 + 辉光 + 暗角。 */
    const val CRT = PRE + SCAN + """
uniform sampler2D glow;
uniform float dim;
uniform float dx;
uniform float period;
uniform float s;
vec2 bump(vec2 p) {
    vec2 c = size * 0.5;
    float d = length(p - c) / (dim * 0.75);
    float k = d < 1.0 ? 1.0 - 0.22 * (1.0 - smoothstep(0.0, 1.0, d)) : 1.0;
    return c + (p - c) * k;
}
vec3 grade(vec3 c) { return contr(satur(c, 1.06), 1.03); }
void main() {
    vec4 c = texture(src, uv);
    vec2 p = P();
    vec3 r = vec3(linU(at(bump(p - vec2(dx, 0.0)))).r, linU(at(bump(p))).g, linU(at(bump(p + vec2(dx, 0.0)))).b);
    r = grade(r);
    r *= scan(size.y - p.y, period, 0.3);
    // 辉光（模糊图上的扫描线平均掉了）
    vec3 bl = grade(texture(glow, bump(p) / size).rgb) * 0.85;
    r = max(r, mix(r, bl, 0.35));
    // 暗角
    float hd = length(size) * 0.5;
    float a = 0.85 * clamp((length(p - size * 0.5) - hd * 0.45) / (hd * 0.6), 0.0, 1.0);
    r *= 1.0 - a;
    o = encU(mix(linU(c), r, s), c.a);
}
"""

    const val VAPORWAVE = PRE + """
uniform vec3 c0;
uniform vec3 c1;
uniform float s;
// 转色相（保持亮度，和 Core Image 的 CIHueAdjust 逐位对得上）
vec3 hue(vec3 c, float a) {
    float co = cos(a), si = sin(a);
    mat3 m = mat3(
        0.213 + co * 0.787 - si * 0.213, 0.213 - co * 0.213 + si * 0.143, 0.213 - co * 0.213 - si * 0.787,
        0.715 - co * 0.715 - si * 0.715, 0.715 + co * 0.285 + si * 0.140, 0.715 - co * 0.715 + si * 0.715,
        0.072 - co * 0.072 + si * 0.928, 0.072 - co * 0.072 - si * 0.283, 0.072 + co * 0.928 + si * 0.072);
    return m * c;
}
void main() {
    vec4 c = texture(src, uv);
    vec3 b = linU(c);
    vec3 mapped = mix(c0, c1, luma(b));
    vec3 r = mix(b, mapped, 0.55);
    r = hue(contr(satur(r, 1.35), 1.05), -0.18);
    o = encU(mix(b, r, s), c.a);
}
"""

    /**
     * CMYK 半调网点：青、品、黄三色各一层网（角度 15°、75°、0°），网点大小按油墨量。
     * 油墨量按线性光算、不另加黑版（对比 Core Image 的结果，这样最像：暗部三色叠成黑）。
     */
    const val HALFTONE = PRE + """
uniform float cell;
uniform float s;
// 某一色的网点覆盖：在旋转网格里找最近的格子中心，取那里的颜色定网点大小
float screenDot(vec2 q, float ang, int ch) {
    float co = cos(ang), si = sin(ang);
    mat2 rot = mat2(co, si, -si, co);
    mat2 inv = mat2(co, -si, si, co);
    vec2 r = rot * q;
    vec2 cc = (floor(r / cell) + 0.5) * cell;
    vec2 qc = inv * cc;
    vec2 pc = vec2(qc.x, size.y - qc.y);
    vec3 ink = 1.0 - linU(at(clamp(pc, vec2(0.5), size - 0.5)));
    float amount = ch == 0 ? ink.r : (ch == 1 ? ink.g : ink.b);
    float rad = cell * 0.7071 * sqrt(clamp(amount, 0.0, 1.0));
    float d = length(r - cc);
    float soft = cell * 0.22;
    return 1.0 - smoothstep(rad - soft, rad + soft, d);
}
void main() {
    vec4 c = texture(src, uv);
    vec2 p = P();
    vec2 q = vec2(p.x, size.y - p.y);
    float C = screenDot(q, 0.2618, 0);
    float M = screenDot(q, 1.309, 1);
    float Y = screenDot(q, 0.0, 2);
    vec3 paper = vec3(1.0 - C, 1.0 - M, 1.0 - Y);
    o = encU(mix(linU(c), paper, s), c.a);
}
"""

    /** 低保真：微微模糊 + 色阶变少 + 褪色。 */
    const val LOFI = PRE + CURVE + """
uniform sampler2D soft;
uniform float s;
void main() {
    vec4 c = texture(src, uv);
    vec3 r = texture(soft, uv).rgb;
    r = floor(clamp(r, 0.0, 1.0) * 8.0 + 0.5) / 8.0;
    r = contr(satur(r, 0.78), 0.9);
    r = tone(r);
    o = encU(mix(linU(c), r, s), c.a);
}
"""

    /** 粒子：颜色乘 k（不透明度不变）再盖上去。 */
    const val PARTICLES = PRE + """
uniform sampler2D layer;
uniform float k;
void main() {
    vec4 c = texture(src, uv);
    vec4 l = linP(texture(layer, uv));
    vec3 r = l.rgb * k + linU(c) * (1.0 - l.a);
    o = encU(r, c.a);
}
"""
}
