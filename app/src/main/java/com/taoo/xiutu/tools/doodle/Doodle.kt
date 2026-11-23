package com.taoo.xiutu.tools.doodle

import android.graphics.Bitmap
import android.graphics.PointF
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.tools.mosaic.strokeHits
import java.lang.ref.SoftReference
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 涂鸦用的颜色（sRGB，0...1）。 */
data class DoodleColor(val r: Float, val g: Float, val b: Float) {
    fun argb(alpha: Float = 1f): Int {
        fun c(v: Float) = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
        return (c(alpha) shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    val isLight: Boolean get() = 0.299f * r + 0.587f * g + 0.114f * b > 0.62f

    /** t = 0 是自己，t = 1 是 other。 */
    fun mixed(other: DoodleColor, t: Float) = DoodleColor(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)

    companion object {
        val white = DoodleColor(1f, 1f, 1f)
        val black = DoodleColor(0f, 0f, 0f)
        val red = DoodleColor(1f, 0.27f, 0.27f)

        /** 面板上的色板：前面是常用色，后面几个是画妆容用的。 */
        val palette = listOf(
            white, black, red,
            DoodleColor(1.0f, 0.58f, 0.0f),
            DoodleColor(1.0f, 0.84f, 0.04f),
            DoodleColor(0.2f, 0.82f, 0.35f),
            DoodleColor(0.2f, 0.78f, 0.9f),
            DoodleColor(0.04f, 0.52f, 1.0f),
            DoodleColor(0.69f, 0.32f, 0.87f),
            DoodleColor(1.0f, 0.45f, 0.7f),
            DoodleColor(0.2f, 0.13f, 0.09f),
            DoodleColor(0.45f, 0.3f, 0.2f),
            DoodleColor(0.72f, 0.36f, 0.38f),
            DoodleColor(0.86f, 0.3f, 0.45f),
            DoodleColor(0.95f, 0.5f, 0.45f),
            DoodleColor(0.93f, 0.7f, 0.66f),
        )

        /** 色相 0...1，饱和度和亮度拉满。 */
        fun hue(h: Float): DoodleColor {
            val x = (h - kotlin.math.floor(h)) * 6
            val i = x.toInt() % 6
            val f = x - x.toInt()
            return when (i) {
                0 -> DoodleColor(1f, f, 0f)
                1 -> DoodleColor(1 - f, 1f, 0f)
                2 -> DoodleColor(0f, 1f, f)
                3 -> DoodleColor(0f, 1 - f, 1f)
                4 -> DoodleColor(f, 0f, 1f)
                else -> DoodleColor(1f, 0f, 1 - f)
            }
        }
    }
}

/** 涂鸦面板里画笔的分组。 */
enum class DoodleCategory(val title: String) {
    PEN("画笔"), MAKEUP("妆容"), PATTERN("图案");

    val brushes: List<DoodleBrush> get() = DoodleBrush.entries.filter { it.category == this }
}

/** 所有画笔。前三组是手绘（跟着手指走的线），标记那一组是拖出来的形状（起点 + 终点）。 */
enum class DoodleBrush(val title: String) {
    PEN("圆头笔"), ARROW_PEN("箭头笔"), MARKER("马克笔"), HIGHLIGHTER("荧光笔"), PENCIL("铅笔"), CALLIGRAPHY("毛笔"),
    CRAYON("蜡笔"), CLOUD("云朵"), SPRAY("喷枪"), DASHED("虚线"), RAINBOW("彩虹"), NEON("霓虹"),
    BROW("眉笔"), EYELINER("眼线"), EYESHADOW("眼影"), BLUSH("腮红"), LIP("口红"), GLOW("高光"),
    STARS("星星"), HEARTS("爱心"), SPARKLES("闪光"), BUBBLES("泡泡"),
    PETALS("樱花"), LEAVES("落叶"), RAINDROPS("雨滴"), SNOWFLAKES("雪花"), NOTES("音符"),
    ARROW("箭头"), LINE("直线"), RECT("方框"), ELLIPSE("圆圈"), BAR("高亮"), NUMBER("序号"), SPOT("聚光"),
    ERASER("橡皮");

    /** null = 不出现在涂鸦的画笔列表里（标记形状和橡皮）。 */
    val category: DoodleCategory?
        get() = when (this) {
            PEN, ARROW_PEN, MARKER, HIGHLIGHTER, PENCIL, CALLIGRAPHY, CRAYON, CLOUD, SPRAY, DASHED, RAINBOW, NEON -> DoodleCategory.PEN
            BROW, EYELINER, EYESHADOW, BLUSH, LIP, GLOW -> DoodleCategory.MAKEUP
            STARS, HEARTS, SPARKLES, BUBBLES, PETALS, LEAVES, RAINDROPS, SNOWFLAKES, NOTES -> DoodleCategory.PATTERN
            else -> null
        }

    /** 标记里的形状：由起点和终点两个点决定。 */
    val isShape: Boolean get() = this in shapes

    /** 标记面板上的图标。 */
    val symbol: String
        get() = when (this) {
            ARROW -> "arrow.up.right"
            LINE -> "line.diagonal"
            RECT -> "rectangle"
            ELLIPSE -> "circle"
            BAR -> "highlighter"
            NUMBER -> "1.circle"
            SPOT -> "circle.dashed"
            else -> "scribble.variable"
        }

    /** 实际线宽 = 面板上的"大小" × 这个倍数。 */
    val widthFactor: Float
        get() = when (this) {
            PEN, ARROW_PEN, DASHED, RAINBOW, LINE, RECT, ELLIPSE, ARROW -> 1f
            PENCIL -> 0.6f
            EYELINER -> 0.7f
            BROW -> 0.9f
            NEON -> 0.9f
            CALLIGRAPHY -> 1.6f
            MARKER -> 1.8f
            HIGHLIGHTER -> 2.6f
            CRAYON -> 2.2f
            LIP -> 1.6f
            CLOUD, SPRAY -> 3.2f
            EYESHADOW, GLOW -> 3.5f
            BLUSH -> 7f
            STARS, HEARTS, SPARKLES, BUBBLES, PETALS, LEAVES, RAINDROPS, SNOWFLAKES, NOTES -> 3.2f
            BAR, NUMBER, SPOT -> 1f
            ERASER -> 2.5f
        }

    /** 选中这支笔时"浓度"滑块的默认值。 */
    val defaultOpacity: Float
        get() = when (this) {
            HIGHLIGHTER -> 0.45f
            MARKER -> 0.9f
            BROW -> 0.5f
            EYELINER -> 0.75f
            EYESHADOW -> 0.45f
            BLUSH -> 0.35f
            LIP -> 0.55f
            GLOW -> 0.4f
            BAR -> 0.4f
            else -> 1f
        }

    /** 选中这支笔时自动换成的颜色；null = 保持当前颜色。 */
    val defaultColor: DoodleColor?
        get() = when (this) {
            BROW -> DoodleColor(0.2f, 0.13f, 0.09f)
            EYELINER -> DoodleColor.black
            EYESHADOW -> DoodleColor(0.72f, 0.36f, 0.38f)
            BLUSH -> DoodleColor(0.95f, 0.5f, 0.45f)
            LIP -> DoodleColor(0.86f, 0.3f, 0.45f)
            GLOW -> DoodleColor.white
            PETALS -> DoodleColor(1.0f, 0.72f, 0.8f)
            LEAVES -> DoodleColor(0.9f, 0.48f, 0.15f)
            RAINDROPS -> DoodleColor(0.72f, 0.88f, 1.0f)
            SNOWFLAKES -> DoodleColor.white
            else -> null
        }

    /** 画笔列表缩略图上用的颜色。 */
    val sampleColor: DoodleColor
        get() = when (this) {
            ARROW_PEN -> DoodleColor.red
            HIGHLIGHTER -> DoodleColor(1.0f, 0.84f, 0.04f)
            MARKER -> DoodleColor(1.0f, 0.58f, 0.0f)
            PENCIL -> DoodleColor(0.12f, 0.12f, 0.12f)
            CALLIGRAPHY -> DoodleColor(0.08f, 0.08f, 0.08f)
            CRAYON -> DoodleColor(0.2f, 0.78f, 0.9f)
            NEON -> DoodleColor(1.0f, 0.3f, 0.75f)
            DASHED -> DoodleColor(0.2f, 0.82f, 0.35f)
            STARS -> DoodleColor(1.0f, 0.84f, 0.04f)
            HEARTS -> DoodleColor(1.0f, 0.35f, 0.5f)
            SPARKLES -> DoodleColor(0.55f, 0.8f, 1.0f)
            BUBBLES -> DoodleColor(0.6f, 0.9f, 1.0f)
            NOTES -> DoodleColor(1.0f, 0.84f, 0.04f)
            else -> defaultColor ?: DoodleColor.white
        }

    companion object {
        val shapes = listOf(ARROW, LINE, RECT, ELLIPSE, BAR, NUMBER, SPOT)
    }
}

/**
 * 一笔。点是归一化的图片坐标（原点左上角），粗细以图片长边为 1。
 * points：手绘是手指经过的点；形状是 [起点, 终点]；序号是 [位置]。
 * opacity 是整笔的不透明度（一笔之内自己叠到自己不会变深）。
 * seed：带随机散布的笔，预览和导出用同一个种子，画出来才一样。
 * jitter：图案笔的随机分布；null = 默认值。
 * region：妆容笔只画在这些范围里（五官）。每一项是一块：第一圈是外轮廓，后面的是挖掉的洞。归一化坐标。
 * feather：范围边缘的羽化宽度（以图片长边为 1）。
 */
data class DoodleStroke(
    val brush: DoodleBrush,
    val points: List<PointF>,
    val width: Float,
    val color: DoodleColor,
    val opacity: Float = 1f,
    val seed: Long = 0,
    val number: Int = 0,
    val jitter: DoodleJitter? = null,
    val region: List<List<List<PointF>>> = emptyList(),
    val feather: Float = 0f,
)

/** 图案笔的随机分布（像 Photoshop 画笔的散布、间距、大小抖动）。 */
data class DoodleJitter(
    /** 间距：相邻两个图案隔多远，按笔的粗细算。 */
    val spacing: Float = 1.25f,
    /** 散布：图案离开手指路线多远，按笔的粗细算。 */
    val scatter: Float = 0.35f,
    /** 大小随机 0...1。 */
    val size: Float = 0.5f,
    /** 角度随机 0...1（1 = 随便转）。 */
    val angle: Float = 0.2f,
    /** 每个落点放几个图案。 */
    val count: Float = 1f,
)

/** 涂鸦 / 标记这一步：画在图上的笔画。 */
class DoodleOp(strokes: List<DoodleStroke>) : EditOp {
    val strokes: List<DoodleStroke> = strokes.toList()

    /** 只有橡皮擦的笔画等于什么都没画。 */
    val isIdentity: Boolean get() = strokes.none { it.brush != DoodleBrush.ERASER }

    // 同一个尺寸只画一遍笔画层：撤销重做、反复重建底图时复用；内存紧张时系统自己回收
    @Volatile private var cache: SoftReference<Pair<Long, Bitmap>>? = null

    override fun apply(src: Bitmap): Bitmap {
        if (isIdentity || src.width < 1 || src.height < 1) return src
        // 图特别大时笔画层按长边 4096 画，再放大
        val k = min(1f, DoodleRenderer.MAX_LAYER_SIDE / max(src.width, src.height))
        val w = max(1, (src.width * k).roundToInt())
        val h = max(1, (src.height * k).roundToInt())
        val key = (w.toLong() shl 32) or h.toLong()
        val hit = cache?.get()?.takeIf { it.first == key }?.second
        val layer = hit ?: DoodleRenderer.layer(strokes, w, h)?.also { cache = SoftReference(key to it) }
        return DoodleRenderer.compose(src, layer?.let { listOf(it to 1f) } ?: emptyList(), strokes.filter { it.brush == DoodleBrush.SPOT })
    }

    override fun reopens(tool: Tool) = tool == Tool.DOODLE || tool == Tool.MARK

    /** 照 iOS tapDecoration：点中最上面那一笔；形状、序号打开标记，否则打开涂鸦（自动圆润拉直的线也只有两个点，按笔来分）。 */
    override fun hitTest(point: PointF, ratio: Float): Tool? {
        val s = strokes.lastOrNull { it.brush != DoodleBrush.ERASER && strokeHits(it.points, it.width, point, ratio) } ?: return null
        return if (s.brush.isShape) Tool.MARK else Tool.DOODLE
    }
}
