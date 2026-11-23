package com.taoo.xiutu.tools.frame

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.Tool
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.serialization.Serializable

/** 边框、背景里用到的颜色（sRGB，0...1）。 */
@Serializable
data class FrameColor(val r: Float, val g: Float, val b: Float) {
    val luma: Float get() = 0.299f * r + 0.587f * g + 0.114f * b
    val isLight: Boolean get() = luma > 0.6f

    /** 压在这个颜色上看得清的颜色（画线、打孔、写字用）。 */
    val contrast: FrameColor get() = if (isLight) FrameColor(0.13f, 0.13f, 0.14f) else FrameColor(0.93f, 0.93f, 0.92f)

    fun argb(alpha: Float = 1f): Int {
        fun c(v: Float) = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
        return (c(alpha) shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    companion object {
        fun of(r: Float, g: Float, b: Float) = FrameColor(r.coerceIn(0f, 1f), g.coerceIn(0f, 1f), b.coerceIn(0f, 1f))
        fun hex(v: Int) = FrameColor(((v shr 16) and 0xFF) / 255f, ((v shr 8) and 0xFF) / 255f, (v and 0xFF) / 255f)
        val white = FrameColor(1f, 1f, 1f)
        val black = FrameColor(0f, 0f, 0f)
    }
}

/** 边框和背景共用的作图工具（Android Canvas，坐标原点左上角）。尺寸都按图片折算，预览和导出一样。 */
object FrameKit {
    fun fillPaint(color: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL }

    /** 圆角半径不超过短边一半。 */
    private fun clampRadius(r: RectF, radius: Float) = min(max(radius, 0f), min(r.width(), r.height()) / 2)

    /** 圆角矩形填色。 */
    fun fillRound(c: Canvas, rect: RectF, radius: Float, color: Int) {
        val rad = clampRadius(rect, radius)
        if (rad > 0) c.drawRoundRect(rect, rad, rad, fillPaint(color)) else c.drawRect(rect, fillPaint(color))
    }

    /** 圆角矩形的一圈线，线画在边界以内。 */
    fun strokeInside(c: Canvas, rect: RectF, radius: Float, lineWidth: Float, color: Int) {
        val lw = max(lineWidth, 0.01f)
        val rad = clampRadius(rect, radius)
        val r = RectF(rect).apply { inset(lw / 2, lw / 2) }
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = lw; strokeJoin = Paint.Join.MITER }
        val rr = max(rad - lw / 2, 0f)
        if (rr > 0) c.drawRoundRect(r, rr, rr, p) else c.drawRect(r, p)
    }

    /**
     * 把照片放进 window：大小一样就只是挪过去；不一样就等比铺满、居中、多出来的裁掉。radius > 0 时切圆角。
     */
    fun drawPhoto(c: Canvas, photo: Bitmap, window: RectF, radius: Float) {
        val w = photo.width.toFloat()
        val h = photo.height.toFloat()
        var img = photo
        val m = Matrix()
        if (abs(w - window.width()) < 0.5f && abs(h - window.height()) < 0.5f) {
            m.setTranslate(window.left.roundToInt().toFloat(), window.top.roundToInt().toFloat())
        } else {
            var f = max(window.width() / w, window.height() / h)
            if (f < 0.75f) {
                // 缩得多时先高质量缩小，免得锯齿
                img = Img.downscale(photo, max(1, (max(w, h) * f).roundToInt()))
                f = max(window.width() / img.width, window.height() / img.height)
            }
            val tx = (window.centerX() - img.width * f / 2).roundToInt().toFloat()
            val ty = (window.centerY() - img.height * f / 2).roundToInt().toFloat()
            m.setScale(f, f)
            m.postTranslate(tx, ty)
        }
        val shader = BitmapShader(img, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply { setLocalMatrix(m) }
        val p = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply { this.shader = shader }
        val rad = clampRadius(window, radius)
        if (rad > 0) c.drawRoundRect(window, rad, rad, p) else c.drawRect(window, p)
    }

    /**
     * 圆角矩形的柔和投影。阴影本来就是糊的，所以在缩小的图上做再放大：
     * 大图也不慢，而且预览和导出的形状完全一样。blur 是高斯的 σ（和 Core Image 的半径一样）。
     */
    fun shadow(c: Canvas, cw: Float, ch: Float, rect: RectF, radius: Float, blur: Float, alpha: Float) {
        if (alpha <= 0 || blur <= 0) return
        val k = min(1f, 420f / max(cw, ch))
        val lw = max(1, (cw * k).roundToInt())
        val lh = max(1, (ch * k).roundToInt())
        val kx = lw / cw
        val ky = lh / ch
        val small = Bitmap.createBitmap(lw, lh, Bitmap.Config.ARGB_8888)
        val sc = Canvas(small)
        val r = RectF(rect.left * kx, rect.top * ky, rect.right * kx, rect.bottom * ky)
        val sigma = max(blur * min(kx, ky), 0.3f)
        // Skia 的模糊半径 → σ = 0.577r + 0.5
        val br = max((sigma - 0.5f) / 0.57735f, 0.1f)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.BLACK; maskFilter = BlurMaskFilter(br, BlurMaskFilter.Blur.NORMAL) }
        val rad = clampRadius(r, radius * min(kx, ky))
        if (rad > 0) sc.drawRoundRect(r, rad, rad, p) else sc.drawRect(r, p)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG).apply { this.alpha = (alpha.coerceIn(0f, 1f) * 255).roundToInt() }
        c.drawBitmap(small, null, RectF(0f, 0f, cw, ch), paint)
    }

    /** 一行字：高度按 height 来，太长就整体缩小到 maxWidth 以内。width/height 是画出来的大小。 */
    class TextLabel(private val text: String, typeface: Typeface, height: Float, maxWidth: Float, color: Int) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.typeface = typeface; this.color = color }
        private val k: Float
        private val ascent: Float
        val width: Float
        val height: Float

        init {
            val drawHeight = height.coerceIn(12f, 320f)
            paint.textSize = drawHeight * 0.74f
            val fm = paint.fontMetrics
            ascent = -fm.ascent
            val tw = paint.measureText(text)
            val bw = min(ceil(tw) + PAD * 2, 8192f)
            val bh = ceil(ascent + fm.descent) + PAD * 2
            var kk = height / bh
            if (bw * kk > maxWidth) kk = maxWidth / bw
            k = kk
            this.width = bw * k
            this.height = bh * k
        }

        fun draw(c: Canvas, x: Float, y: Float) {
            c.save()
            c.translate(x, y)
            c.scale(k, k)
            c.drawText(text, PAD, PAD + ascent, paint)
            c.restore()
        }

        companion object {
            private const val PAD = 3f

            fun make(text: String, typeface: Typeface, height: Float, maxWidth: Float, color: Int): TextLabel? =
                if (text.isEmpty() || height < 1 || maxWidth < 1) null else TextLabel(text, typeface, height, maxWidth, color)
        }
    }

    /** 新建画布。 */
    fun canvasBitmap(w: Int, h: Int): Bitmap = Bitmap.createBitmap(max(1, w), max(1, h), Bitmap.Config.ARGB_8888)
}

// MARK: - 边框

enum class FrameStyle {
    NONE, SOLID, LINE, DOUBLE, CARD, POLAROID, FILM, STAMP, MAGAZINE;

    /** 能不能在边框上写一行字。 */
    val hasCaption: Boolean get() = this == POLAROID || this == MAGAZINE
    /** 细线内框本来就画在照片里面，没有"向内 / 向外"之分。 */
    val canGoInside: Boolean get() = this != NONE && this != LINE
    /** 除了边框本身的颜色，还有一层垫在后面的底色。 */
    val hasBacking: Boolean get() = this == STAMP
}

/**
 * 边框：给照片加一圈边（白边、拍立得、胶片边……）。所有尺寸都按照片短边的比例算。
 * inside = false：边框加在照片外面，画布变大；true：画布不变，边框往照片里占。
 */
@Serializable
data class FrameParams(
    val style: FrameStyle = FrameStyle.NONE,
    /** 边框（纸）的颜色。 */
    val color: FrameColor = FrameColor.white,
    /** 垫在纸后面的底色（邮票用）。 */
    val backing: FrameColor = FrameColor(0.80f, 0.82f, 0.85f),
    /** 粗细，0...1。 */
    val width: Float = 0.35f,
    /** 照片的圆角，0...1。 */
    val radius: Float = 0f,
    val inside: Boolean = false,
    /** 拍立得、杂志留白上写的一行字。 */
    val caption: String = "",
) {
    val isIdentity: Boolean get() = style == FrameStyle.NONE

    fun apply(photo: Bitmap): Bitmap {
        if (style == FrameStyle.NONE) return photo
        val w = photo.width.toFloat()
        val h = photo.height.toFloat()
        if (w < 8 || h < 8) return photo
        val s = min(w, h)
        val wd = width.coerceIn(0f, 1f)
        val b = s * (0.012f + 0.1f * wd)
        val corner = s * 0.16f * radius.coerceIn(0f, 1f)

        if (style == FrameStyle.LINE) {
            // 细线内框：照片不动，往里收一点画一圈细线
            val inset = s * (0.018f + 0.09f * wd)
            val lineWidth = s * (0.0028f + 0.004f * wd)
            val out = photo.copy(Bitmap.Config.ARGB_8888, true)
            FrameKit.strokeInside(Canvas(out), RectF(inset, inset, w - inset, h - inset), corner, lineWidth, color.argb())
            return out
        }

        // 四边各留多宽
        var left = b; var right = b; var top = b; var bottom = b
        var outer = 0f
        val portrait = h >= w
        when (style) {
            FrameStyle.DOUBLE -> { left = b * 1.5f; right = left; top = left; bottom = left }
            FrameStyle.CARD -> { left = b * 1.7f; right = left; top = left; bottom = left }
            FrameStyle.POLAROID -> bottom = b * 4.2f
            FrameStyle.FILM -> {
                // 齿孔在长边那两侧
                val strip = b * 2.3f
                val end = b * 0.7f
                if (portrait) { left = strip; right = strip; top = end; bottom = end } else { top = strip; bottom = strip; left = end; right = end }
            }
            FrameStyle.STAMP -> { outer = b; left = b * 2.3f; right = left; top = left; bottom = left }
            FrameStyle.MAGAZINE -> { left = b * 1.3f; right = left; top = left; bottom = b * 3.8f }
            else -> {}
        }
        if (inside) {
            // 边框再宽，也至少留一半给照片
            val k = minOf(1f, w * 0.5f / (left + right), h * 0.5f / (top + bottom))
            left *= k; right *= k; top *= k; bottom *= k; outer *= k
        }
        left = max(1f, left.roundToInt().toFloat()); right = max(1f, right.roundToInt().toFloat())
        top = max(1f, top.roundToInt().toFloat()); bottom = max(1f, bottom.roundToInt().toFloat())

        val cw: Float
        val ch: Float
        val window: RectF
        if (inside) {
            cw = w; ch = h
            window = RectF(left, top, w - right, h - bottom)
        } else {
            cw = w + left + right; ch = h + top + bottom
            window = RectF(left, top, left + w, top + h)
        }
        val out = FrameKit.canvasBitmap(cw.roundToInt(), ch.roundToInt())
        val c = Canvas(out)
        val ink = color.contrast
        var photoRadius = corner
        c.drawColor((if (style == FrameStyle.STAMP) backing else color).argb())

        // 照片下面的东西
        when (style) {
            FrameStyle.CARD -> {
                photoRadius = max(corner, s * 0.035f)
                FrameKit.shadow(c, cw, ch, RectF(window).apply { offset(0f, left * 0.13f) }, photoRadius, left * 0.3f, 0.42f)
            }
            FrameStyle.FILM -> {
                val strip = if (portrait) left else top
                val along = strip * 0.30f
                val across = strip * 0.46f
                val pitch = strip * 0.72f
                val hole = strip * 0.07f
                val length = if (portrait) ch else cw
                val count = max(1, ((length - pitch * 0.3f) / pitch).toInt())
                val start = (length - (count - 1) * pitch) / 2
                for (side in 0 until 2) {
                    for (i in 0 until count) {
                        val along0 = start + i * pitch
                        val r = if (portrait) {
                            val x = if (side == 0) strip / 2 else cw - strip / 2
                            RectF(x - across / 2, along0 - along / 2, x + across / 2, along0 + along / 2)
                        } else {
                            val y = if (side == 0) strip / 2 else ch - strip / 2
                            RectF(along0 - along / 2, y - across / 2, along0 + along / 2, y + across / 2)
                        }
                        FrameKit.fillRound(c, r, hole, ink.argb())
                    }
                }
            }
            FrameStyle.STAMP -> {
                val paper = RectF(outer, outer, cw - outer, ch - outer)
                FrameKit.shadow(c, cw, ch, RectF(paper).apply { offset(0f, outer * 0.14f) }, 0f, outer * 0.3f, 0.32f)
                // 邮票纸：沿四条边咬出一排圆孔
                val bite = outer * 0.3f
                val nx = max(3f, (paper.width() / (bite * 3.1f)).roundToInt().toFloat())
                val ny = max(3f, (paper.height() / (bite * 3.1f)).roundToInt().toFloat())
                val px = paper.width() / nx
                val py = paper.height() / ny
                c.saveLayer(0f, 0f, cw, ch, null)
                c.drawRect(paper, FrameKit.fillPaint(color.argb()))
                val clear = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT); this.color = android.graphics.Color.BLACK }
                if (bite > 0) {
                    for (i in 0..nx.toInt()) {
                        val x = paper.left + i * px
                        c.drawCircle(x, paper.top, bite, clear)
                        c.drawCircle(x, paper.bottom, bite, clear)
                    }
                    for (j in 0..ny.toInt()) {
                        val y = paper.top + j * py
                        c.drawCircle(paper.left, y, bite, clear)
                        c.drawCircle(paper.right, y, bite, clear)
                    }
                }
                c.restore()
            }
            else -> {}
        }

        // 照片
        FrameKit.drawPhoto(c, photo, window, photoRadius)

        // 压在最上面的线和字
        val text = caption.trim()
        when (style) {
            FrameStyle.DOUBLE -> {
                val gap = left * 0.42f
                FrameKit.strokeInside(
                    c, RectF(window).apply { inset(-gap, -gap) }, if (photoRadius > 0) photoRadius + gap else 0f,
                    max(left * 0.075f, s * 0.0015f), ink.argb(0.85f),
                )
            }
            FrameStyle.POLAROID -> {
                FrameKit.TextLabel.make(text, Typeface.create("casual", Typeface.BOLD), bottom * 0.4f, window.width() * 0.92f, ink.argb())?.let { label ->
                    val x = (window.centerX() - label.width / 2).roundToInt().toFloat()
                    val y = ((bottom - label.height) / 2).roundToInt().toFloat()
                    label.draw(c, x, ch - y - label.height)
                }
            }
            FrameStyle.MAGAZINE -> {
                FrameKit.TextLabel.make(text, Typeface.create(Typeface.SERIF, Typeface.BOLD), bottom * 0.3f, window.width() * 0.92f, ink.argb())?.let { label ->
                    val barY = (bottom * 0.66f).roundToInt().toFloat()
                    val barW = (bottom * 0.5f).roundToInt().toFloat()
                    val barH = max(1f, (bottom * 0.035f).roundToInt().toFloat())
                    c.drawRect(window.left, ch - barY - barH, window.left + barW, ch - barY, FrameKit.fillPaint(ink.argb()))
                    val y = max((bottom * 0.56f - label.height).roundToInt().toFloat(), 0f)
                    label.draw(c, window.left, ch - y - label.height)
                }
            }
            else -> {}
        }
        return out
    }
}

/** 边框面板里的一个个样式。点一个就换成它这套默认参数。 */
class FramePreset(val id: String, val title: String, val params: FrameParams) {
    companion object {
        val all = listOf(
            FramePreset("none", "无", FrameParams(FrameStyle.NONE)),
            FramePreset("white", "白边", FrameParams(FrameStyle.SOLID)),
            FramePreset("black", "黑边", FrameParams(FrameStyle.SOLID, color = FrameColor(0.04f, 0.04f, 0.04f))),
            FramePreset("line", "细线", FrameParams(FrameStyle.LINE, width = 0.3f)),
            FramePreset("double", "双线", FrameParams(FrameStyle.DOUBLE, color = FrameColor.hex(0xF6F2EA))),
            FramePreset("card", "卡片", FrameParams(FrameStyle.CARD, color = FrameColor.hex(0xECEDEF), radius = 0.35f)),
            FramePreset("polaroid", "拍立得", FrameParams(FrameStyle.POLAROID, color = FrameColor.hex(0xFBFAF6), width = 0.4f)),
            FramePreset("film", "胶片", FrameParams(FrameStyle.FILM, color = FrameColor(0.05f, 0.05f, 0.05f), width = 0.3f)),
            FramePreset("stamp", "邮票", FrameParams(FrameStyle.STAMP, color = FrameColor.hex(0xFAF8F2), width = 0.3f)),
            FramePreset("magazine", "杂志", FrameParams(FrameStyle.MAGAZINE, width = 0.4f)),
        )
    }
}

/** 边框这一步。 */
class FrameOp(val params: FrameParams) : EditOp {
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
    override val changesCanvas: Boolean get() = true
    override fun reopens(tool: Tool) = tool == Tool.FRAME
}
