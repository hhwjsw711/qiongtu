package com.taoo.xiutu.tools.frame

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.Shaders
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.serialization.Serializable

/** 画布比例。value = 宽 / 高，原比例没有固定值。 */
enum class BackdropRatio(val title: String, val value: Float?) {
    ORIGINAL("原比例", null), R1X1("1:1", 1f), R3X4("3:4", 3f / 4), R4X3("4:3", 4f / 3), R4X5("4:5", 4f / 5),
    R9X16("9:16", 9f / 16), R16X9("16:9", 16f / 9), R2X3("2:3", 2f / 3), R3X2("3:2", 3f / 2),
}

enum class BackdropFill(val title: String, val symbol: String) {
    BLUR("模糊", "drop"), SOLID("纯色", "square.fill"), GRADIENT("渐变", "circle.lefthalf.filled"),
    CHECKS("格子", "checkerboard.rectangle"), DOTS("波点", "circle.grid.3x3"), STRIPES("条纹", "line.diagonal");

    val isPattern: Boolean get() = this == CHECKS || this == DOTS || this == STRIPES
}

/**
 * 背景：把照片放到一块更大的画布上（指定比例，背景用模糊的照片、纯色、渐变或图案）。
 * 照片保持原来的像素不缩小，是画布按比例变大；所有尺寸都是相对值，预览和导出一样。
 */
@Serializable
data class BackdropParams(
    val ratio: BackdropRatio = BackdropRatio.ORIGINAL,
    /** 照片在画布里占多大：1 = 刚好顶满，越小四周留得越多。 */
    val scale: Float = 1f,
    /** 照片在空出来的地方里的位置，-1...1；x 正 = 往右，y 正 = 往下。 */
    val offsetX: Float = 0f,
    val offsetY: Float = 0f,
    /** 照片的圆角，0...1。 */
    val radius: Float = 0f,
    /** 照片的投影，0...1。 */
    val shadow: Float = 0f,
    val fill: BackdropFill = BackdropFill.BLUR,
    /** 纯色 / 渐变的第一个颜色 / 图案的底色。 */
    val colorA: FrameColor = FrameColor.white,
    /** 渐变的第二个颜色 / 图案的颜色。 */
    val colorB: FrameColor = FrameColor.hex(0xE9E4DA),
    /** 渐变方向（度）：0 = 从左到右，90 = 从上到下。 */
    val angle: Float = 90f,
    /** 模糊程度，0...1。 */
    val blur: Float = 0.55f,
    /** 模糊背景压暗多少，0...1。 */
    val dim: Float = 0.2f,
    /** 图案的大小，0...1。 */
    val pattern: Float = 0.4f,
) {
    /** 画布和照片一样大、又没有圆角时，背景一点都露不出来，等于没改。 */
    val isIdentity: Boolean get() = ratio == BackdropRatio.ORIGINAL && scale >= 0.999f && radius <= 0

    /** 照片是 w × h 时画布有多大（还没算导出时的封顶）：先按比例把照片包住，再按 scale 把画布放大（照片不缩）。 */
    fun canvasSize(w: Float, h: Float): Pair<Float, Float> {
        if (w <= 0 || h <= 0) return w to h
        val aspect = ratio.value ?: (w / h)
        var cw = w
        var ch = h
        if (w / h > aspect) ch = w / aspect else cw = h * aspect
        val grow = 1 / scale.coerceIn(0.3f, 1f)
        return cw * grow to ch * grow
    }

    fun apply(input: Bitmap): Bitmap {
        if (isIdentity) return input
        var photo = input
        var w = photo.width.toFloat()
        var h = photo.height.toFloat()
        if (w < 8 || h < 8) return input

        var (cw, ch) = canvasSize(w, h)
        // 太大就整体缩小（照片和画布一起缩，比例关系不变）
        val long = max(cw, ch)
        if (long > MAX_CANVAS) {
            val f = MAX_CANVAS / long
            photo = Img.downscale(photo, max(1, floor(max(w, h) * f).toInt()))
            w = photo.width.toFloat(); h = photo.height.toFloat()
            cw *= f; ch *= f
        }
        cw = max(w, cw.roundToInt().toFloat())
        ch = max(h, ch.roundToInt().toFloat())
        val short = min(cw, ch)

        // 照片的位置（取整，照片才不会被重新采样变糊）
        val freeX = cw - w
        val freeY = ch - h
        val px = (freeX / 2 + offsetX.coerceIn(-1f, 1f) * freeX / 2).roundToInt().toFloat()
        val py = (freeY / 2 + offsetY.coerceIn(-1f, 1f) * freeY / 2).roundToInt().toFloat()
        val window = RectF(px, py, px + w, py + h)

        val out = FrameKit.canvasBitmap(cw.toInt(), ch.toInt())
        val c = Canvas(out)

        // 背景
        when (fill) {
            BackdropFill.BLUR -> blurred(photo, c, cw, ch)
            BackdropFill.SOLID -> c.drawColor(colorA.argb())
            BackdropFill.GRADIENT -> {
                val rad = angle * PI.toFloat() / 180
                val dx = cos(rad)
                val dy = sin(rad)
                val half = (abs(cw * dx) + abs(ch * dy)) / 2
                val p = Paint().apply {
                    shader = LinearGradient(
                        cw / 2 - dx * half, ch / 2 - dy * half, cw / 2 + dx * half, ch / 2 + dy * half,
                        colorA.argb(), colorB.argb(), Shader.TileMode.CLAMP,
                    )
                }
                c.drawRect(0f, 0f, cw, ch, p)
            }
            BackdropFill.CHECKS, BackdropFill.DOTS, BackdropFill.STRIPES -> {
                c.drawColor(colorA.argb())
                val cell = short * (0.025f + 0.11f * pattern.coerceIn(0f, 1f))
                drawPattern(c, cw, ch, max(cell, 1f))
            }
        }

        // 照片的投影和照片
        val side = min(w, h)
        val corner = side * 0.14f * radius.coerceIn(0f, 1f)
        val depth = shadow.coerceIn(0f, 1f)
        if (depth > 0) {
            FrameKit.shadow(
                c, cw, ch, RectF(window).apply { offset(0f, short * 0.012f * depth) }, corner,
                short * (0.008f + 0.03f * depth), 0.25f + 0.3f * depth,
            )
        }
        FrameKit.drawPhoto(c, photo, window, corner)
        return out
    }

    /** 图案：格子、错开排列的波点、45° 斜条纹（和 iOS 一样从左下角起算）。 */
    private fun drawPattern(c: Canvas, cw: Float, ch: Float, cell: Float) {
        val p = FrameKit.fillPaint(colorB.argb())
        when (fill) {
            BackdropFill.CHECKS -> {
                val cols = ceil(cw / cell).toInt()
                val rows = ceil(ch / cell).toInt()
                for (row in 0 until rows) {
                    // row 从下往上数
                    val bottom = ch - row * cell
                    for (col in 0 until cols) {
                        if ((col + row) % 2 == 1) c.drawRect(col * cell, bottom - cell, (col + 1) * cell, bottom, p)
                    }
                }
            }
            BackdropFill.DOTS -> {
                val r = cell * 0.27f
                val rows = ceil(ch / cell).toInt()
                val cols = ceil(cw / cell).toInt() + 1
                for (row in 0 until rows) {
                    val cy = ch - (row * cell + cell / 2)
                    val shift = (row % 2) * 0.5f * cell
                    for (k in 0..cols) c.drawCircle(k * cell + cell / 2 - shift, cy, r, p)
                }
            }
            else -> {
                // 条纹：条和空一样宽，垂直于条纹的方向是 (1, 1)/√2（向上为正）
                val period = max(cell * 1.4f, 2f)
                val step = period / 0.70710677f
                p.style = Paint.Style.STROKE
                p.strokeWidth = period * 0.5f
                p.strokeCap = Paint.Cap.BUTT
                val nMax = ceil((cw + ch) / step).toInt() + 1
                for (n in -1..nMax) {
                    // x + (ch - y) = (n + 0.5) · step  →  x = y + (n + 0.5) · step − ch
                    val k = (n + 0.5f) * step - ch
                    val y0 = -period
                    val y1 = ch + period
                    c.drawLine(y0 + k, y0, y1 + k, y1, p)
                }
            }
        }
    }

    /** 模糊背景：照片缩小 → 铺满画布并放大一点 → 模糊、压暗 → 再放大回画布的大小。 */
    private fun blurred(photo: Bitmap, c: Canvas, cw: Float, ch: Float) {
        val k = min(1f, 480f / max(cw, ch))
        val lw = max(2, (cw * k).roundToInt())
        val lh = max(2, (ch * k).roundToInt())
        val f = max(lw.toFloat() / photo.width, lh.toFloat() / photo.height) * 1.12f
        val small = if (f < 1) Img.downscale(photo, max(1, (max(photo.width, photo.height) * f).roundToInt())) else photo
        val low = Bitmap.createBitmap(lw, lh, Bitmap.Config.ARGB_8888)
        val sw = photo.width * f
        val sh = photo.height * f
        Canvas(low).drawBitmap(
            small, null, RectF(lw / 2f - sw / 2, lh / 2f - sh / 2, lw / 2f + sw / 2, lh / 2f + sh / 2),
            Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG),
        )
        val gain = 1 - 0.65f * dim.coerceIn(0f, 1f)
        val sigma = max(lw, lh) * (0.012f + 0.07f * blur.coerceIn(0f, 1f))
        val soft = runCatching {
            Gpu.run {
                val t = upload(low)
                val b = blur(t, sigma * 2.5f)
                read(pass(GAIN, mapOf("src" to b), mapOf("gain" to gain), lw, lh))
            }
        }.getOrElse { it.printStackTrace(); low }
        c.drawBitmap(soft, null, RectF(0f, 0f, cw, ch), Paint(Paint.FILTER_BITMAP_FLAG))
    }

    companion object {
        /** 导出时画布长边最多这么大（照片本身更大就以照片为准，不再往外放）。 */
        const val MAX_CANVAS = 8192f

        private const val GAIN = Shaders.HEADER + """
uniform sampler2D src;
uniform float gain;
void main() {
    vec4 c = texture(src, uv);
    o = vec4(c.rgb * gain, c.a);
}
"""
    }
}

/** 背景这一步。 */
class BackdropOp(val params: BackdropParams) : EditOp {
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
    override val changesCanvas: Boolean get() = true
    override fun reopens(tool: Tool) = tool == Tool.BACKDROP
}
