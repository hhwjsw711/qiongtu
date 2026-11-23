package com.taoo.xiutu.tools.effect

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * 特效里用 Canvas 画的东西：粒子、光束、光斑、图案（iOS 用 CoreGraphics 画的那些）。
 * 画布先上下翻转成 y 朝上，和 iOS 的坐标一样，iOS 的画法可以逐行照搬；同一个 seed 画出来的位置和 iOS 一样。
 * 尺寸都按画面长边的比例（和 iOS 一致），预览和原图画出来一样。
 */
internal object EffectDraw {
    /** 画布最长边：再大的原图也只画这么大，用的时候放大（省内存）。 */
    const val MAX_SIDE = 2048

    /** 在长边不超过 2048 的透明画布上画（y 朝上），返回画好的图（宽高比和 w×h 一样）。 */
    fun overlay(w: Int, h: Int, seed: Long, chaos: Float = 0.5f, draw: (Canvas, Float, Float, EffectRNG, Paint) -> Unit): Bitmap? {
        val long = max(w, h)
        if (long < 2) return null
        val k = min(1f, MAX_SIDE.toFloat() / long)
        val ow = max(2, (w * k).roundToInt())
        val oh = max(2, (h * k).roundToInt())
        val bmp = Bitmap.createBitmap(ow, oh, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.translate(0f, oh.toFloat())
        c.scale(1f, -1f)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        draw(c, ow.toFloat(), oh.toFloat(), EffectRNG(seed, chaos), paint)
        return bmp
    }

    private fun rgb(r: Float, g: Float, b: Float, a: Float = 1f): Int = Color.argb(a.coerceIn(0f, 1f), r, g, b)

    private fun hex(v: Int, a: Float = 1f): Int = ((a.coerceIn(0f, 1f) * 255f).roundToInt() shl 24) or (v and 0xFFFFFF)

    private fun withAlpha(c: Int, a: Float): Int = ((a.coerceIn(0f, 1f) * 255f).roundToInt() shl 24) or (c and 0xFFFFFF)

    private fun alphaOf(c: Int): Float = (c ushr 24) / 255f

    private fun fill(p: Paint, color: Int) {
        p.shader = null
        p.style = Paint.Style.FILL
        p.color = color
    }

    private fun stroke(p: Paint, color: Int, width: Float, cap: Paint.Cap = Paint.Cap.BUTT) {
        p.shader = null
        p.style = Paint.Style.STROKE
        p.color = color
        p.strokeWidth = width
        p.strokeCap = cap
    }

    private fun deg(rad: Float) = (rad * 180.0 / PI).toFloat()

    /** 中间亮、边上透明的一团光。 */
    private fun glow(c: Canvas, p: Paint, x: Float, y: Float, r: Float, color: Int, core: Float = 0f) {
        if (r <= 0.01f) return
        p.style = Paint.Style.FILL
        p.color = Color.WHITE
        p.shader = RadialGradient(x, y, r, intArrayOf(color, color, withAlpha(color, 0f)), floatArrayOf(0f, core, 1f), Shader.TileMode.CLAMP)
        c.drawCircle(x, y, r, p)
        p.shader = null
    }

    /** 四角星（闪光）。 */
    private fun sparkle(c: Canvas, p: Paint, x: Float, y: Float, r: Float, color: Int, rotation: Float = 0f) {
        c.save()
        c.translate(x, y)
        c.rotate(deg(rotation))
        val path = Path()
        val n = 4
        for (i in 0 until n * 2) {
            val a = i * PI.toFloat() / n + PI.toFloat() / 2
            val rr = if (i % 2 == 0) r else r * 0.14f
            val px = cos(a) * rr
            val py = sin(a) * rr
            if (i == 0) path.moveTo(px, py) else path.lineTo(px, py)
        }
        path.close()
        fill(p, color)
        c.drawPath(path, p)
        c.restore()
        glow(c, p, x, y, r * 0.55f, withAlpha(color, alphaOf(color) * 0.45f))
    }

    private fun heart(c: Canvas, p: Paint, x: Float, y: Float, s: Float, color: Int, rotation: Float) {
        c.save()
        c.translate(x, y)
        c.rotate(deg(rotation))
        val path = Path()
        path.moveTo(0f, -s * 0.5f)
        path.cubicTo(-s * 0.2f, -s * 0.25f, -s * 0.5f, -s * 0.15f, -s * 0.5f, s * 0.12f)
        // 两个半圆从左到右经过上方（y 朝上）
        val r = s * 0.25f
        path.arcTo(RectF(-s * 0.25f - r, s * 0.14f - r, -s * 0.25f + r, s * 0.14f + r), 180f, -180f)
        path.arcTo(RectF(s * 0.25f - r, s * 0.14f - r, s * 0.25f + r, s * 0.14f + r), 180f, -180f)
        path.cubicTo(s * 0.5f, -s * 0.15f, s * 0.2f, -s * 0.25f, 0f, -s * 0.5f)
        path.close()
        fill(p, color)
        c.drawPath(path, p)
        c.restore()
    }

    /** 两头尖的叶片 / 花瓣。 */
    private fun leaf(c: Canvas, p: Paint, x: Float, y: Float, length: Float, width: Float, rotation: Float, color: Int, notch: Boolean) {
        c.save()
        c.translate(x, y)
        c.rotate(deg(rotation))
        val path = Path()
        val l = length / 2
        path.moveTo(-l, 0f)
        path.quadTo(0f, width, l, 0f)
        if (notch) {
            // 樱花瓣尖上有个小缺口。
            path.lineTo(l * 0.82f, -width * 0.08f)
            path.lineTo(l * 0.95f, -width * 0.3f)
        }
        path.quadTo(0f, -width, -l, 0f)
        path.close()
        fill(p, color)
        c.drawPath(path, p)
        if (!notch) {
            stroke(p, rgb(0f, 0f, 0f, 0.18f), max(0.5f, width * 0.06f))
            c.drawLine(-l, 0f, l * 0.9f, 0f, p)
        }
        c.restore()
    }

    // MARK: 氛围粒子

    fun particles(kind: EffectKind, c: Canvas, W: Float, H: Float, rng: EffectRNG, p: Paint) {
        val u = max(W, H)
        fun pt(): Pair<Float, Float> {
            val x = rng.next().toFloat() * W
            val y = rng.next().toFloat() * H
            return x to y
        }
        fun r(a: Double, b: Double) = rng.range(a, b).toFloat()
        fun pick(list: IntArray) = list[(rng.next() * list.size).toInt() % list.size]
        val density = (W * H / (u * u)).toDouble() // 横竖图粒子密度一样
        fun count(n: Double) = max(1, (n * density * 1.4).toInt())
        when (kind) {
            EffectKind.GOLD_GLITTER -> {
                val golds = intArrayOf(0xFFD66B, 0xFFF0B8, 0xF2B544, 0xFFE28A, 0xE8A33A)
                repeat(count(320.0)) {
                    val (x, y) = pt()
                    val rad = u * r(0.0012, 0.0042)
                    val col = pick(golds)
                    fill(p, hex(col, r(0.55, 1.0)))
                    c.drawOval(x - rad, y - rad, x + rad, y + rad, p)
                }
                repeat(count(22.0)) {
                    val (x, y) = pt()
                    val size = u * r(0.008, 0.022)
                    val col = hex(0xFFF3C4, r(0.7, 1.0))
                    sparkle(c, p, x, y, size, col, r(-0.3, 0.3))
                }
            }
            EffectKind.TWINKLE -> {
                repeat(count(110.0)) {
                    val (x, y) = pt()
                    val rad = u * r(0.001, 0.0028)
                    fill(p, rgb(1f, 1f, 1f, r(0.4, 0.9)))
                    c.drawOval(x - rad, y - rad, x + rad, y + rad, p)
                }
                repeat(count(34.0)) {
                    val (x, y) = pt()
                    val size = u * r(0.008, 0.032)
                    val col = rgb(1f, 1f, 0.97f, r(0.65, 1.0))
                    sparkle(c, p, x, y, size, col, r(-0.15, 0.15))
                }
            }
            EffectKind.SNOW, EffectKind.COLOR_SNOW -> {
                val colors = intArrayOf(0xFFB3C7, 0xB3E0FF, 0xFFF1A8, 0xC9B8FF, 0xB8FFD6, 0xFFFFFF)
                repeat(count(if (kind == EffectKind.SNOW) 260.0 else 220.0)) {
                    val (x, y) = pt()
                    // 有大有小：大的离镜头近，更虚。
                    val near = rng.next() < 0.12
                    val rad = u * (if (near) r(0.008, 0.016) else r(0.0015, 0.005))
                    val color = if (kind == EffectKind.SNOW) {
                        rgb(1f, 1f, 1f, if (near) r(0.35, 0.6) else r(0.6, 0.95))
                    } else {
                        val col = pick(colors)
                        hex(col, if (near) 0.5f else r(0.7, 1.0))
                    }
                    glow(c, p, x, y, rad, color, if (near) 0.1f else 0.55f)
                }
            }
            EffectKind.PETALS -> {
                val pinks = intArrayOf(0xFFC7D9, 0xFFB0C8, 0xFFDCE6, 0xF9A6BF)
                repeat(count(70.0)) {
                    val len = u * r(0.012, 0.026)
                    val (x, y) = pt()
                    val w = len * r(0.38, 0.5)
                    val rot = r(0.0, 6.28)
                    val col = pick(pinks)
                    leaf(c, p, x, y, len, w, rot, hex(col, r(0.75, 0.95)), notch = true)
                }
            }
            EffectKind.LEAVES -> {
                val autumn = intArrayOf(0xD9541E, 0xE8862A, 0xF2B33D, 0xB8341B, 0xC96A1F, 0x9A4A1A)
                repeat(count(48.0)) {
                    val len = u * r(0.016, 0.038)
                    val (x, y) = pt()
                    val w = len * r(0.3, 0.42)
                    val rot = r(0.0, 6.28)
                    val col = pick(autumn)
                    leaf(c, p, x, y, len, w, rot, hex(col, r(0.85, 1.0)), notch = false)
                }
            }
            EffectKind.CONFETTI -> {
                val bright = intArrayOf(0xFF4D6D, 0xFFC93C, 0x3CC8FF, 0x7CFF6B, 0xB46BFF, 0xFF8A3C, 0xFFFFFF, 0xFF6BD5)
                fun pickColor(): Int {
                    val col = pick(bright)
                    return hex(col, r(0.85, 1.0))
                }
                repeat(count(170.0)) {
                    val (x, y) = pt()
                    val w = u * r(0.004, 0.009)
                    val h = w * r(1.4, 2.4)
                    c.save()
                    c.translate(x, y)
                    c.rotate(deg(r(0.0, 6.28)))
                    fill(p, pickColor())
                    c.drawRect(-w / 2, -h / 2, w / 2, h / 2, p)
                    c.restore()
                }
                // 卷曲的彩带。
                repeat(count(14.0)) {
                    val (sx, sy) = pt()
                    val len = u * r(0.05, 0.1)
                    val ang = r(0.0, 6.28)
                    val ex = sx + cos(ang) * len
                    val ey = sy + sin(ang) * len
                    val bend = u * r(0.02, 0.04)
                    val col = pickColor()
                    val lw = u * r(0.0025, 0.004)
                    stroke(p, col, lw, Paint.Cap.ROUND)
                    val path = Path()
                    path.moveTo(sx, sy)
                    path.cubicTo(
                        sx + cos(ang + 1.3f) * bend + cos(ang) * len * 0.33f, sy + sin(ang + 1.3f) * bend + sin(ang) * len * 0.33f,
                        sx + cos(ang - 1.3f) * bend + cos(ang) * len * 0.66f, sy + sin(ang - 1.3f) * bend + sin(ang) * len * 0.66f,
                        ex, ey,
                    )
                    c.drawPath(path, p)
                }
            }
            EffectKind.HEARTS -> {
                val reds = intArrayOf(0xFF4D7A, 0xFF8FAB, 0xFF2E55, 0xFFB3C6, 0xE0245E)
                repeat(count(40.0)) {
                    val (x, y) = pt()
                    val size = u * r(0.012, 0.04)
                    val col = pick(reds)
                    val a = r(0.55, 0.92)
                    heart(c, p, x, y, size, hex(col, a), r(-0.4, 0.4))
                }
            }
            EffectKind.BUBBLES -> {
                repeat(count(34.0)) {
                    val (x, y) = pt()
                    val rad = u * r(0.008, 0.035)
                    glow(c, p, x, y, rad, rgb(0.85f, 0.95f, 1f, 0.07f), 0.7f)
                    stroke(p, rgb(1f, 1f, 1f, r(0.45, 0.75)), max(0.8f, u * 0.0016f))
                    c.drawOval(x - rad, y - rad, x + rad, y + rad, p)
                    val hr = rad * 0.28f
                    fill(p, rgb(1f, 1f, 1f, 0.7f))
                    val hx = x - rad * 0.55f - hr / 2
                    val hy = y + rad * 0.35f - hr / 4
                    c.drawOval(hx, hy, hx + hr, hy + hr * 0.6f, p)
                }
            }
            EffectKind.FIREFLIES -> {
                repeat(count(70.0)) {
                    val (x, y) = pt()
                    val rad = u * r(0.003, 0.009)
                    glow(c, p, x, y, rad * 3, rgb(1f, 0.92f, 0.45f, r(0.12, 0.25)))
                    glow(c, p, x, y, rad, rgb(1f, 1f, 0.8f, 0.95f), 0.4f)
                }
            }
            EffectKind.RAIN -> {
                val ang = -PI.toFloat() / 2 + 0.22f
                repeat(count(520.0)) {
                    val (x, y) = pt()
                    val len = u * r(0.025, 0.07)
                    val col = rgb(0.92f, 0.95f, 1f, r(0.18, 0.45))
                    stroke(p, col, max(0.6f, u * r(0.0006, 0.0013)), Paint.Cap.ROUND)
                    c.drawLine(x, y, x + cos(ang) * len, y + sin(ang) * len, p)
                }
            }
            else -> {}
        }
    }

    // MARK: 光

    /** 从上面一个角斜射下来的光束。 */
    fun godRays(c: Canvas, W: Float, H: Float, rng: EffectRNG, p: Paint, fromLeft: Boolean, v: EffectVariant) {
        val u = max(W, H)
        val sx = if (fromLeft) -W * 0.08f else W * 1.08f
        val sy = H * 1.1f
        val toward = atan2(-H, if (fromLeft) W * 0.7f else -W * 0.7f)
        repeat(11) {
            val a = toward + rng.range(-0.42, 0.42).toFloat()
            val half = rng.range(0.008, 0.035).toFloat()
            val reach = u * rng.range(1.0, 1.5).toFloat()
            val alpha = rng.range(0.25, 0.6).toFloat()
            val path = Path()
            path.moveTo(sx, sy)
            path.lineTo(sx + cos(a - half) * reach, sy + sin(a - half) * reach)
            path.lineTo(sx + cos(a + half) * reach, sy + sin(a + half) * reach)
            path.close()
            c.save()
            c.clipPath(path)
            val col = rgb(v.r, v.g, v.b, alpha)
            p.style = Paint.Style.FILL
            p.shader = RadialGradient(sx, sy, reach, col, withAlpha(col, 0f), Shader.TileMode.CLAMP)
            c.drawCircle(sx, sy, reach, p)
            p.shader = null
            c.restore()
        }
        glow(c, p, sx, sy, u * 0.45f, rgb(v.r, v.g, v.b, 0.55f))
    }

    /** 一道斜着的彩虹色光带。 */
    fun rainbow(c: Canvas, W: Float, H: Float, rng: EffectRNG, p: Paint) {
        val u = max(W, H)
        val colors = intArrayOf(0xFF3B3B, 0xFF9A2E, 0xFFE93B, 0x4BE36B, 0x3BB8FF, 0x6B5BFF, 0xC04BFF).map { hex(it, 0.55f) }.toIntArray()
        c.save()
        c.translate(W * rng.range(0.25, 0.55).toFloat(), H * 0.5f)
        c.rotate(deg(rng.range(0.5, 0.9).toFloat()))
        val band = u * 0.09f
        p.style = Paint.Style.FILL
        p.shader = LinearGradient(-band / 2, 0f, band / 2, 0f, colors, null, Shader.TileMode.CLAMP)
        c.drawRect(-band / 2, -u, band / 2, u, p)
        p.shader = null
        c.restore()
    }

    /** 焦外的圆形光斑。color 为空时用彩色。 */
    fun bokehSpots(c: Canvas, W: Float, H: Float, rng: EffectRNG, p: Paint, color: EffectVariant?) {
        val u = max(W, H)
        val palette = intArrayOf(0xFF8FB1, 0xFFD36B, 0x7FD8FF, 0xB79BFF, 0x8CFFB5)
        val n = (30 * W * H / (u * u) * 1.4f).toInt() + 8
        repeat(n) {
            val x = rng.next().toFloat() * W
            val y = rng.next().toFloat() * H
            val rad = u * rng.range(0.015, 0.06).toFloat()
            val a = rng.range(0.16, 0.38).toFloat()
            val col = if (color != null) rgb(color.r, color.g, color.b, a)
            else hex(palette[(rng.next() * palette.size).toInt() % palette.size], a)
            fill(p, col)
            c.drawOval(x - rad, y - rad, x + rad, y + rad, p)
            // 边缘一圈略亮，像镜头的光斑。
            stroke(p, withAlpha(col, min(1f, a * 1.6f)), max(1f, rad * 0.06f))
            c.drawOval(x - rad, y - rad, x + rad, y + rad, p)
        }
    }

    /** 树叶缝里漏下来的光（白 = 亮）。 */
    fun leafPattern(c: Canvas, W: Float, H: Float, rng: EffectRNG, p: Paint) {
        val u = max(W, H)
        c.drawColor(Color.BLACK)
        fill(p, Color.WHITE)
        // 一簇一簇的光斑，簇里大小不一。
        repeat((55 * W * H / (u * u) * 1.4f + 16).toInt()) {
            val cx = rng.next().toFloat() * W
            val cy = rng.next().toFloat() * H
            repeat(9) {
                val x = cx + u * rng.range(-0.045, 0.045).toFloat()
                val y = cy + u * rng.range(-0.045, 0.045).toFloat()
                val rw = u * rng.range(0.003, 0.014).toFloat()
                val rh = rw * rng.range(0.45, 1.0).toFloat()
                c.save()
                c.translate(x, y)
                c.rotate(deg(rng.range(0.0, 3.14).toFloat()))
                c.drawOval(-rw, -rh, rw, rh, p)
                c.restore()
            }
        }
    }

    /** 百叶窗的条纹光影（白 = 亮）。 */
    fun blindsPattern(c: Canvas, W: Float, H: Float, p: Paint) {
        val u = max(W, H)
        c.drawColor(Color.BLACK)
        c.save()
        c.translate(W / 2, H / 2)
        c.rotate(deg(-0.42f))
        fill(p, Color.WHITE)
        val period = u * 0.065f
        var y = -u
        while (y < u) {
            c.drawRect(-u, y, u, y + period * 0.52f, p)
            y += period
        }
        c.restore()
    }

    /**
     * 星芒：在画面最亮的几处画出放射状的星芒。small 是缩到长边 72 左右的画面（行 0 是上边）。
     * 返回 w×h 比例的叠加图；找不到够亮的点时返回 null。
     */
    fun stars(small: Bitmap, w: Int, h: Int, points: Int, seed: Long = 1, chaos: Float = 0.5f): Bitmap? {
        val sw = small.width
        val sh = small.height
        if (sw < 3 || sh < 3) return null
        val px = IntArray(sw * sh)
        small.getPixels(px, 0, sw, 0, 0, sw, sh)
        fun lum(x: Int, y: Int): Double {
            val c = px[y * sw + x]
            return (0.3 * ((c shr 16) and 0xFF) + 0.59 * ((c shr 8) and 0xFF) + 0.11 * (c and 0xFF)) / 255.0
        }
        // 局部最亮、而且够亮的点。y 换成朝上的坐标（和 iOS 一样）。
        class Spot(val x: Double, val y: Double, val v: Double)
        var maxL = 0.0
        for (y in 0 until sh) for (x in 0 until sw) maxL = max(maxL, lum(x, y))
        val threshold = max(0.78, maxL * 0.93)
        val found = ArrayList<Spot>()
        for (y in 1 until max(1, sh - 1)) {
            for (x in 1 until max(1, sw - 1)) {
                val v = lum(x, y)
                if (v < threshold) continue
                var peak = true
                for (dy in -1..1) for (dx in -1..1) if ((dx != 0 || dy != 0) && lum(x + dx, y + dy) > v) peak = false
                if (peak) found += Spot((x + 0.5) / sw, 1 - (y + 0.5) / sh, v)
            }
        }
        found.sortByDescending { it.v }
        // 太近的只留一个。
        val picked = ArrayList<Spot>()
        for (f in found) {
            if (picked.size >= 12) break
            if (picked.all { hypot(it.x - f.x, it.y - f.y) > 0.08 }) picked += f
        }
        if (picked.isEmpty()) return null
        return overlay(w, h, seed, chaos) { c, W, H, rng, p ->
            val u = max(W, H)
            picked.forEachIndexed { i, f ->
                val len = u * (if (i == 0) 0.17f else 0.1f) * (0.6 + (f.v - threshold) / max(0.01, 1 - threshold) * 0.4).toFloat()
                ray(c, p, (f.x * W).toFloat(), (f.y * H).toFloat(), len * rng.range(0.8, 1.2).toFloat(), points, rng)
            }
        }
    }

    private fun ray(c: Canvas, p: Paint, x: Float, y: Float, length: Float, points: Int, rng: EffectRNG) {
        val white = rgb(1f, 0.97f, 0.9f, 1f)
        // 整颗星转一个小角度，每根芒长短不一（随机度越高差得越多）。
        val turn = rng.range(-0.12, 0.12).toFloat()
        for (i in 0 until points) {
            val a = i * PI.toFloat() / points * 2 + PI.toFloat() / 4 + turn
            val each = length * rng.range(0.85, 1.15).toFloat()
            val ex = x + cos(a) * each
            val ey = y + sin(a) * each
            val half = length * 0.028f
            val nx = -sin(a) * half
            val ny = cos(a) * half
            val path = Path()
            path.moveTo(x + nx, y + ny)
            path.lineTo(ex, ey)
            path.lineTo(x - nx, y - ny)
            path.close()
            p.style = Paint.Style.FILL
            p.shader = LinearGradient(x, y, ex, ey, white, withAlpha(white, 0f), Shader.TileMode.CLAMP)
            c.drawPath(path, p)
            p.shader = null
        }
        glow(c, p, x, y, length * 0.16f, rgb(1f, 0.97f, 0.9f, 0.9f), 0.15f)
    }
}
