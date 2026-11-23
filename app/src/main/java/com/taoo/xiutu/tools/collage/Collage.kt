package com.taoo.xiutu.tools.collage

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** 拼图画布的比例。value = 宽 / 高。 */
enum class CollageRatio(val title: String, val value: Float) {
    R3X4("3:4", 3f / 4), R1X1("1:1", 1f), R4X3("4:3", 4f / 3), R4X5("4:5", 4f / 5),
    R2X3("2:3", 2f / 3), R3X2("3:2", 3f / 2), R9X16("9:16", 9f / 16), R16X9("16:9", 16f / 9),
}

/** 拼图里用到的颜色（背景、间隔）。 */
data class CollageColor(val r: Float, val g: Float, val b: Float) {
    fun argb(): Int {
        fun c(v: Float) = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
        return (0xFF shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    companion object {
        val WHITE = CollageColor(1f, 1f, 1f)

        val palette = listOf(
            WHITE,
            CollageColor(0f, 0f, 0f),
            CollageColor(0.93f, 0.93f, 0.93f),
            CollageColor(0.96f, 0.93f, 0.86f),
            CollageColor(0.99f, 0.86f, 0.88f),
            CollageColor(0.84f, 0.91f, 0.98f),
            CollageColor(0.85f, 0.93f, 0.85f),
            CollageColor(0.99f, 0.93f, 0.70f),
            CollageColor(0.20f, 0.22f, 0.26f),
        )
    }
}

/** 归一化的矩形（原点左上角）。 */
data class NRect(val x: Float, val y: Float, val w: Float, val h: Float) {
    val maxX get() = x + w
    val maxY get() = y + h
}

/** 模板的切法：一格，或者横着 / 竖着按比例切成几块，可以嵌套。 */
sealed class CollageSplit {
    data object Cell : CollageSplit()
    class H(val parts: List<Pair<Float, CollageSplit>>) : CollageSplit()
    class V(val parts: List<Pair<Float, CollageSplit>>) : CollageSplit()

    /** 切出来的每一格，归一化坐标，原点左上角。 */
    fun rects(rect: NRect = NRect(0f, 0f, 1f, 1f)): List<NRect> = when (this) {
        Cell -> listOf(rect)
        is H -> {
            val total = parts.sumOf { it.first.toDouble() }.toFloat()
            var x = rect.x
            parts.flatMap { (weight, part) ->
                val w = rect.w * weight / total
                part.rects(NRect(x, rect.y, w, rect.h)).also { x += w }
            }
        }
        is V -> {
            val total = parts.sumOf { it.first.toDouble() }.toFloat()
            var y = rect.y
            parts.flatMap { (weight, part) ->
                val h = rect.h * weight / total
                part.rects(NRect(rect.x, y, rect.w, h)).also { y += h }
            }
        }
    }

    companion object {
        /** 横着排的几格，参数是各格的宽度比例。 */
        fun cols(vararg weights: Float): CollageSplit = H(weights.map { it to Cell })

        /** 竖着排的几格，参数是各格的高度比例。 */
        fun rows(vararg weights: Float): CollageSplit = V(weights.map { it to Cell })

        fun grid(rows: Int, cols: Int): CollageSplit = V((0 until rows).map { 1f to H((0 until cols).map { 1f to Cell }) })

        fun h(vararg parts: Pair<Float, CollageSplit>): CollageSplit = H(parts.toList())
        fun v(vararg parts: Pair<Float, CollageSplit>): CollageSplit = V(parts.toList())
    }
}

/** 一个拼图模板：画布被切成几格。 */
class CollageLayout(
    val id: String,
    /** 每一格在画布里的位置，归一化坐标，原点左上角。 */
    val cells: List<NRect>,
    /** 从第几格开始是叠在上面的"画中画"小格；等于 cells.size 表示没有。 */
    val insetFrom: Int,
    /** 最适合的画布比例（"全部"里按这个比例显示）。 */
    val natural: CollageRatio,
) {
    override fun equals(other: Any?) = other is CollageLayout && other.id == id
    override fun hashCode() = id.hashCode()

    /** 这个模板放在这种比例的画布上会不会切出太细长的格子。 */
    fun fits(ratio: CollageRatio): Boolean {
        for (cell in cells.take(insetFrom)) {
            val aspect = cell.w * ratio.value / cell.h
            if (aspect > 3.3f || aspect < 1 / 3.3f) return false
        }
        return true
    }

    companion object {
        private fun make(id: String, natural: CollageRatio, split: CollageSplit, insets: List<NRect> = emptyList()): CollageLayout {
            val base = split.rects()
            return CollageLayout(id, base + insets, base.size, natural)
        }

        private val big: CollageSplit get() = CollageSplit.h(2f to CollageSplit.Cell, 1f to CollageSplit.rows(1f, 1f))

        /** 全部模板，按格子数从少到多。 */
        val all: List<CollageLayout> by lazy {
            val S = CollageSplit
            val C = CollageSplit.Cell
            listOf(
                // 2 格
                make("2h", CollageRatio.R1X1, S.cols(1f, 1f)),
                make("2v", CollageRatio.R3X4, S.rows(1f, 1f)),
                make("2h21", CollageRatio.R4X3, S.cols(2f, 1f)),
                make("2h12", CollageRatio.R4X3, S.cols(1f, 2f)),
                make("2v21", CollageRatio.R3X4, S.rows(2f, 1f)),
                make("2v12", CollageRatio.R3X4, S.rows(1f, 2f)),
                make("2pip", CollageRatio.R3X4, C, listOf(NRect(0.24f, 0.3f, 0.52f, 0.4f))),
                // 3 格
                make("3h", CollageRatio.R3X2, S.cols(1f, 1f, 1f)),
                make("3v", CollageRatio.R2X3, S.rows(1f, 1f, 1f)),
                make("3l", CollageRatio.R1X1, S.h(1f to C, 1f to S.rows(1f, 1f))),
                make("3r", CollageRatio.R1X1, S.h(1f to S.rows(1f, 1f), 1f to C)),
                make("3t", CollageRatio.R3X4, S.v(1f to C, 1f to S.cols(1f, 1f))),
                make("3b", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f), 1f to C)),
                make("3l2", CollageRatio.R4X3, big),
                make("3t2", CollageRatio.R3X4, S.v(2f to C, 1f to S.cols(1f, 1f))),
                make("3pip", CollageRatio.R3X4, S.rows(1f, 1f), listOf(NRect(0.27f, 0.34f, 0.46f, 0.32f))),
                // 4 格
                make("4g", CollageRatio.R1X1, S.grid(2, 2)),
                make("4h", CollageRatio.R16X9, S.cols(1f, 1f, 1f, 1f)),
                make("4v", CollageRatio.R9X16, S.rows(1f, 1f, 1f, 1f)),
                make("4l", CollageRatio.R4X3, S.h(2f to C, 1f to S.rows(1f, 1f, 1f))),
                make("4t", CollageRatio.R3X4, S.v(2f to C, 1f to S.cols(1f, 1f, 1f))),
                make("4b", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f, 1f), 2f to C)),
                make("4m", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f), 1f to S.cols(1f, 2f))),
                // 5 格
                make("5a", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f), 1f to S.cols(1f, 1f, 1f))),
                make("5b", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f, 1f), 1f to S.cols(1f, 1f))),
                make("5c", CollageRatio.R4X3, S.h(1f to S.rows(1f, 1f), 1f to S.rows(1f, 1f, 1f))),
                make("5d", CollageRatio.R4X3, S.h(1f to C, 1f to S.grid(2, 2))),
                make("5e", CollageRatio.R3X4, S.v(2f to C, 1f to S.cols(1f, 1f), 1f to S.cols(1f, 1f))),
                make("5pip", CollageRatio.R1X1, S.grid(2, 2), listOf(NRect(0.3f, 0.3f, 0.4f, 0.4f))),
                // 6 格
                make("6a", CollageRatio.R3X4, S.grid(3, 2)),
                make("6b", CollageRatio.R4X3, S.grid(2, 3)),
                make("6c", CollageRatio.R1X1, S.v(2f to big, 1f to S.cols(1f, 1f, 1f))),
                make("6d", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f, 1f), 2f to S.cols(1f, 1f), 1f to C)),
                // 7 格
                make("7a", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f), 1f to S.cols(1f, 1f, 1f), 1f to S.cols(1f, 1f))),
                make("7b", CollageRatio.R1X1, S.v(2f to big, 1f to S.cols(1f, 1f, 1f, 1f))),
                // 8 格
                make("8a", CollageRatio.R3X4, S.v(1f to S.cols(1f, 1f, 1f), 1f to S.cols(1f, 1f), 1f to S.cols(1f, 1f, 1f))),
                make("8b", CollageRatio.R3X4, S.grid(4, 2)),
                // 9 格
                make("9a", CollageRatio.R1X1, S.grid(3, 3)),
                make("9b", CollageRatio.R3X4, S.v(2f to big, 1f to S.cols(1f, 1f, 1f), 1f to S.cols(1f, 1f, 1f))),
            )
        }

        /** 一个模板最多能放几张图。 */
        val maxCells: Int by lazy { all.maxOf { it.cells.size } }
    }
}

/**
 * 从相册加进来的一张图。大图不以解开的位图留在内存里（拼接可以一直加图），
 * 而是压成 JPEG、导出时再解码：每张只占一两 MB。实时预览只用小图。
 */
class CollageImage(private val jpeg: ByteArray?, private val bitmap: Bitmap?, val width: Int, val height: Int) {
    fun decode(): Bitmap? = bitmap ?: jpeg?.let { Img.decode(it) }
}

/** 拼图里的一张图，以及它在格子里怎么摆。 */
data class CollagePicture(
    val id: String = UUID.randomUUID().toString(),
    /** true = 正在编辑的这张图（渲染时再传进来）；false = 从相册加进来的图。 */
    val isBase: Boolean = false,
    val image: CollageImage? = null,
    /** 实时预览用的小图。 */
    val small: Bitmap? = null,
    /** 模板里图片在格子内的平移：-1...1，对应"铺满格子后多出来的部分"的两头。 */
    val ox: Float = 0f,
    val oy: Float = 0f,
    /** 模板里图片在格子内的放大倍数，1 = 刚好铺满。 */
    val zoom: Float = 1f,
    val flip: Boolean = false,
    /** 顺时针转了几个 90°。 */
    val quarterTurns: Int = 0,
    /** 拼接时沿拼接方向裁掉的比例：开头（竖拼 = 上面，横拼 = 左边）和结尾。 */
    val cropStart: Float = 0f,
    val cropEnd: Float = 0f,
) {
    /** 拼接时留下的比例。 */
    val keep: Float get() = max(1f - cropStart - cropEnd, 0.05f)
}

enum class CollageMode(val title: String) { TEMPLATE("模板"), STITCH("拼接") }

/**
 * 拼图：把当前这张图和另外几张图拼成一张，作为编辑历史里的一步。
 * 所有尺寸都按画布大小折算，预览图和原图导出拼出来的样子一致。
 */
data class CollageParams(
    val mode: CollageMode = CollageMode.TEMPLATE,
    /** 拼进来的图，按顺序放进格子（模板）或者依次接起来（拼接）。 */
    val pictures: List<CollagePicture> = listOf(CollagePicture(isBase = true)),
    // 模板
    val layout: CollageLayout = CollageLayout.all[0],
    val ratio: CollageRatio = CollageRatio.R1X1,
    /** 格子之间的间距、四周的边距、格子的圆角，都相对于画布短边。 */
    val gap: Float = 0.012f,
    val margin: Float = 0.012f,
    val corner: Float = 0f,
    val background: CollageColor = CollageColor.WHITE,
    // 拼接
    /** true = 竖拼（上下接），false = 横拼（左右接）。 */
    val vertical: Boolean = true,
    /** 拼接时图与图之间的间隔，相对于图的宽（竖拼）或高（横拼）；0 = 无缝。 */
    val stitchGap: Float = 0f,
) {
    /** 只有正在编辑的这一张、没加别的图：等于没拼。 */
    val isIdentity
        get() = pictures.isEmpty() || (
            pictures.size == 1 && pictures[0].isBase &&
                (mode == CollageMode.TEMPLATE || (pictures[0].cropStart == 0f && pictures[0].cropEnd == 0f))
            )

    /** 模板里放不下的图有几张。 */
    val hiddenCount get() = if (mode == CollageMode.TEMPLATE) max(0, pictures.size - layout.cells.size) else 0

    // MARK: 排版

    /** 第 index 张图摆正之后的尺寸。refW/refH = 正在编辑的图的尺寸。 */
    fun pictureSize(index: Int, refW: Float, refH: Float): Pair<Float, Float> {
        val p = pictures[index]
        var w = refW
        var h = refH
        val img = p.image
        if (!p.isBase && img != null) { w = img.width.toFloat(); h = img.height.toFloat() }
        if (p.quarterTurns % 2 != 0) { val t = w; w = h; h = t }
        return max(w, 1f) to max(h, 1f)
    }

    /** 拼接时每张图沿拼接方向的"自然长度"（没裁过的整张）：以另一边为 1。 */
    fun stitchFullLengths(refW: Float, refH: Float): List<Float> = pictures.indices.map { i ->
        val (w, h) = pictureSize(i, refW, refH)
        if (vertical) h / w else w / h
    }

    /** 拼接时每张图裁过之后沿拼接方向的长度。 */
    private fun stitchLengths(refW: Float, refH: Float): List<Float> =
        stitchFullLengths(refW, refH).mapIndexed { i, length -> length * pictures[i].keep }

    /** 拼出来的画布有多大（像素）。preview = true 时长图按预览的上限算；排版比例不受影响。 */
    fun canvasSize(refW: Float, refH: Float, preview: Boolean = false): Pair<Float, Float> = when (mode) {
        CollageMode.TEMPLATE -> {
            val long = min(maxOf(refW, refH, 16f), MAX_TEMPLATE_SIDE)
            val r = ratio.value
            if (r >= 1) long.roundToInt().toFloat() to (long / r).roundToInt().toFloat()
            else (long * r).roundToInt().toFloat() to long.roundToInt().toFloat()
        }
        CollageMode.STITCH -> {
            val lengths = stitchLengths(refW, refH)
            val cross = max(if (vertical) refW else refH, 16f)
            val total = (lengths.sum() + stitchGap * max(lengths.size - 1, 0)) * cross
            var k = 1f
            k = min(k, (if (preview) PREVIEW_STITCH_SIDE else MAX_STITCH_SIDE) / max(cross, total))
            k = min(k, sqrt((if (preview) PREVIEW_STITCH_PIXELS else MAX_STITCH_PIXELS) / max(cross * total, 1f)))
            val a = max((cross * k).roundToInt().toFloat(), 2f)
            val b = max((total * k).roundToInt().toFloat(), 2f)
            if (vertical) a to b else b to a
        }
    }

    /**
     * 每一格（模板）或每一张图（拼接）在画布里的位置，原点左上角。
     * canvas 可以是输出的像素尺寸，也可以是屏幕上显示的尺寸，算出来的比例一样。
     */
    fun frames(cw: Float, ch: Float, refW: Float, refH: Float): List<RectF> = when (mode) {
        CollageMode.TEMPLATE -> {
            val short = min(cw, ch)
            val m = margin * short
            val half = gap * short / 2
            val iw = cw - m * 2
            val ih = ch - m * 2
            layout.cells.mapIndexed { index, cell ->
                var x0 = m + cell.x * iw
                var x1 = m + cell.maxX * iw
                var y0 = m + cell.y * ih
                var y1 = m + cell.maxY * ih
                if (index < layout.insetFrom) {
                    // 贴着画布边的那一侧不留间距，只有格子之间留。
                    if (cell.x > 0.001f) x0 += half
                    if (cell.maxX < 0.999f) x1 -= half
                    if (cell.y > 0.001f) y0 += half
                    if (cell.maxY < 0.999f) y1 -= half
                }
                x0 = x0.roundToInt().toFloat(); x1 = x1.roundToInt().toFloat()
                y0 = y0.roundToInt().toFloat(); y1 = y1.roundToInt().toFloat()
                RectF(x0, y0, x0 + max(x1 - x0, 1f), y0 + max(y1 - y0, 1f))
            }
        }
        CollageMode.STITCH -> {
            val lengths = stitchLengths(refW, refH)
            if (lengths.isEmpty()) emptyList() else {
                val along = if (vertical) ch else cw
                val cross = if (vertical) cw else ch
                val natural = lengths.sum() + stitchGap * (lengths.size - 1)
                // 画布的长度是取整过的，这里按比例摊回去，相邻两张共用同一条取整后的边，中间不会漏缝。
                val unit = along / max(natural, 0.0001f)
                var cursor = 0f
                lengths.mapIndexed { i, length ->
                    val start = (cursor * unit).roundToInt().toFloat()
                    cursor += length
                    val end = if (i == lengths.size - 1) along else (cursor * unit).roundToInt().toFloat()
                    cursor += stitchGap
                    val len = max(end - start, 1f)
                    if (vertical) RectF(0f, start, cross, start + len) else RectF(start, 0f, start + len, cross)
                }
            }
        }
    }

    /** 模板里第 index 张图铺满它的格子之后，横竖各多出来多少（和 cell 同一个单位）。拖动图片时用。 */
    fun fillExcess(index: Int, cellW: Float, cellH: Float, refW: Float, refH: Float): Pair<Float, Float> {
        val (w, h) = pictureSize(index, refW, refH)
        val s = max(cellW / w, cellH / h) * max(pictures[index].zoom, 1f)
        return max(w * s - cellW, 0f) to max(h * s - cellH, 0f)
    }

    // MARK: 渲染

    /** preview = true：实时预览，用小图、用快的缩放方式，并且把空格子画成浅灰色。 */
    fun render(base: Bitmap, preview: Boolean): Bitmap {
        if (isIdentity && !preview) return base
        val refW = base.width.toFloat()
        val refH = base.height.toFloat()
        val (cw, ch) = canvasSize(refW, refH, preview)
        val rects = frames(cw, ch, refW, refH)
        val out = Bitmap.createBitmap(max(1, cw.toInt()), max(1, ch.toInt()), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(background.argb())

        fun source(index: Int): Bitmap? {
            val p = pictures[index]
            return if (p.isBase) base else (if (preview) p.small else null) ?: p.image?.decode()
        }

        when (mode) {
            CollageMode.TEMPLATE -> {
                val short = min(cw, ch)
                val radius = corner * short
                for ((index, rect) in rects.withIndex()) {
                    if (index >= layout.insetFrom) {
                        // 画中画的小格外面留一圈背景色的边，和底下的图分开。
                        val border = max(gap * short, short * 0.004f)
                        val frame = RectF(rect.left - border, rect.top - border, rect.right + border, rect.bottom + border)
                        shape(canvas, frame, if (radius > 0) radius + border else 0f, background.argb())
                    }
                    val img = if (index < pictures.size) source(index) else null
                    if (img != null) {
                        val p = pictures[index]
                        fill(canvas, img, p.quarterTurns, p.flip, rect, p.ox, p.oy, p.zoom, radius, hq = !preview)
                    } else if (preview) {
                        shape(canvas, rect, radius, EMPTY_CELL)
                    }
                }
            }
            CollageMode.STITCH -> {
                for ((index, rect) in rects.withIndex()) {
                    val img = source(index) ?: continue
                    val p = pictures[index]
                    if (p.cropStart > 0f || p.cropEnd > 0f) {
                        // 沿拼接方向裁掉两头：整张图按没裁时的长度铺开，只露出留下的那一段。
                        val full = (if (vertical) rect.height() else rect.width()) / p.keep
                        val whole = if (vertical) {
                            val top = rect.top - full * p.cropStart
                            RectF(rect.left, top, rect.right, top + full)
                        } else {
                            val left = rect.left - full * p.cropStart
                            RectF(left, rect.top, left + full, rect.bottom)
                        }
                        canvas.save()
                        canvas.clipRect(rect)
                        fill(canvas, img, p.quarterTurns, p.flip, whole, 0f, 0f, 1f, 0f, hq = !preview)
                        canvas.restore()
                    } else {
                        fill(canvas, img, p.quarterTurns, p.flip, rect, 0f, 0f, 1f, 0f, hq = !preview)
                    }
                }
            }
        }
        return out
    }

    companion object {
        /** 模板最长边的上限。 */
        const val MAX_TEMPLATE_SIDE = 8000f
        /**
         * 拼接长图的上限：最长边和总像素。只卡 8000 的话，十来张图拼下来宽度只剩几百像素，没法看，
         * 所以导出放到 20000 / 3600 万像素；屏幕上的实时预览用小得多的上限。
         */
        const val MAX_STITCH_SIDE = 20000f
        const val MAX_STITCH_PIXELS = 36_000_000f
        const val PREVIEW_STITCH_SIDE = 8000f
        const val PREVIEW_STITCH_PIXELS = 10_000_000f

        private val EMPTY_CELL = android.graphics.Color.rgb(214, 214, 219)

        /** 一块纯色的（圆角）矩形。 */
        private fun shape(canvas: Canvas, rect: RectF, radius: Float, color: Int) {
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
            val r = min(radius, min(rect.width(), rect.height()) / 2)
            if (r > 0.5f) canvas.drawRoundRect(rect, r, r, paint) else canvas.drawRect(rect, paint)
        }

        /**
         * 先水平翻转、再顺时针转 turns 个 90°，铺满 target，多出来的部分按 offset 取舍，再按圆角裁掉四个角。
         * 着色器用边缘延伸的方式取样：缩放时不会把图外面的透明混进最边上一圈，拼接的接缝处不会透出背景色。
         */
        private fun fill(
            canvas: Canvas, image: Bitmap, turns: Int, flip: Boolean, target: RectF,
            ox: Float, oy: Float, zoom: Float, radius: Float, hq: Boolean,
        ) {
            val tw = target.width()
            val th = target.height()
            if (image.width < 1 || image.height < 1 || tw < 1 || th < 1) return
            val n = ((turns % 4) + 4) % 4
            val ow = (if (n % 2 == 1) image.height else image.width).toFloat()
            val oh = (if (n % 2 == 1) image.width else image.height).toFloat()
            val s = max(tw / ow, th / oh) * max(zoom, 1f)
            var bmp = image
            if (hq && s < 0.999f) {
                // 缩得多时先高质量缩小
                bmp = Img.downscale(image, max(1, (max(image.width, image.height) * s).roundToInt()))
            }
            val bs = s * image.width / max(bmp.width, 1)
            val ex = max(ow * s - tw, 0f)
            val ey = max(oh * s - th, 0f)
            val cx = target.centerX() + ox.coerceIn(-1f, 1f) * ex / 2
            val cy = target.centerY() + oy.coerceIn(-1f, 1f) * ey / 2
            val left = (cx - ow * s / 2).roundToInt()
            val top = (cy - oh * s / 2).roundToInt()
            val m = Matrix()
            m.postTranslate(-bmp.width / 2f, -bmp.height / 2f)
            if (flip) m.postScale(-1f, 1f)
            if (n != 0) m.postRotate(90f * n)
            m.postScale(bs, bs)
            m.postTranslate(left + ow * s / 2, top + oh * s / 2)
            val shader = BitmapShader(Img.soft(bmp), Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            shader.setLocalMatrix(m)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
            paint.shader = shader
            val r = min(radius, min(tw, th) / 2)
            if (r > 0.5f) canvas.drawRoundRect(target, r, r, paint) else canvas.drawRect(target, paint)
        }
    }
}

/** 拼图这一步：会改变画布大小。 */
class CollageOp(val params: CollageParams) : EditOp {
    override val changesCanvas: Boolean get() = true

    override fun apply(src: Bitmap): Bitmap = params.render(src, preview = false)
}

/** 把相册里选回来的图读成拼图用的图。 */
object CollageImport {
    /** 摆正方向，长边缩到 3072 以内；另外备一张小图给实时预览用。阻塞，后台线程调。 */
    fun picture(context: Context, uri: Uri): CollagePicture? = runCatching {
        val full = Img.decode(context, uri, 3072) ?: return null
        // 带透明的图（PNG）先垫上白底，不然压成 JPEG 后透明的地方会变黑。
        val flat = Bitmap.createBitmap(full.width, full.height, Bitmap.Config.ARGB_8888)
        Canvas(flat).apply {
            drawColor(android.graphics.Color.WHITE)
            drawBitmap(full, 0f, 0f, null)
        }
        flat.setHasAlpha(false)
        val small = Img.downscale(flat, 1100)
        val jpeg = runCatching { Img.jpeg(flat, 95) }.getOrNull()?.takeIf { it.isNotEmpty() }
        // 压不成就退回普通位图。
        val image = if (jpeg != null) CollageImage(jpeg, null, flat.width, flat.height) else CollageImage(null, flat, flat.width, flat.height)
        CollagePicture(image = image, small = small)
    }.getOrNull()
}
