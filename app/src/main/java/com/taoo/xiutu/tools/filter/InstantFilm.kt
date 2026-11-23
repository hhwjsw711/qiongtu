package com.taoo.xiutu.tools.filter

import android.graphics.Bitmap
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.tools.color.ColorFx
import com.taoo.xiutu.tools.color.ColorParams
import com.taoo.xiutu.tools.color.Look
import com.taoo.xiutu.tools.color.V3
import kotlinx.serialization.Serializable

/** 相纸颜色（0...1 的 sRGB）。 */
@Serializable
data class PaperColor(val r: Float, val g: Float, val b: Float) {
    constructor(hex: Int) : this(((hex shr 16) and 0xFF) / 255f, ((hex shr 8) and 0xFF) / 255f, (hex and 0xFF) / 255f)

    val luma get() = 0.299f * r + 0.587f * g + 0.114f * b
    val isLight get() = luma > 0.6f
    val argb: Int get() = (0xFF shl 24) or ((r * 255 + 0.5f).toInt() shl 16) or ((g * 255 + 0.5f).toInt() shl 8) or (b * 255 + 0.5f).toInt()

    companion object {
        val WHITE = PaperColor(1f, 1f, 1f)
        val BLACK = PaperColor(0f, 0f, 0f)
    }
}

/** 相纸正面的质感：哑光纸框、光面塑料、撕拉片。 */
enum class InstantSurface { MATTE, GLOSSY, PEEL }

/** 尺寸（毫米）是按各种相纸公开规格取的近似值。 */
class InstantSpec(
    val paperW: Float, val paperH: Float,
    val imageW: Float, val imageH: Float,
    /** 画面上方那条边；下方写字的宽边 = 剩下的。 */
    val top: Float,
    val imageRadius: Float = 0f,
    val paperRadius: Float = 0.8f,
    val surface: InstantSurface = InstantSurface.MATTE,
) {
    /** rotated = 把相纸横过来（或竖过来）拍：宽边转到右侧。 */
    fun geometry(rotated: Boolean): InstantGeometry {
        val side = (paperW - imageW) / 2
        val chin = paperH - imageH - top
        return if (rotated) InstantGeometry(imageH, imageW, top, chin, side, side, imageRadius, paperRadius, true)
        else InstantGeometry(imageW, imageH, side, side, top, chin, imageRadius, paperRadius, false)
    }
}

/** 摆好方向之后各条边有多宽（毫米）。 */
class InstantGeometry(
    val imageW: Float, val imageH: Float,
    val left: Float, val right: Float, val top: Float, val bottom: Float,
    val imageRadius: Float, val paperRadius: Float,
    /** 写字的那条宽边是不是转到了右侧。 */
    val chinOnRight: Boolean,
)

enum class InstantFormat(val spec: InstantSpec?) {
    NONE(null),
    // 方形宝丽来：88×107，画面 79×79。
    POLAROID(InstantSpec(88f, 107f, 79f, 79f, 6f)),
    // 小号方形：54×67，画面 47×46。
    GO(InstantSpec(54f, 67f, 47f, 46f, 4.5f, paperRadius = 0.6f)),
    // mini：54×86，画面 46×62。
    MINI(InstantSpec(54f, 86f, 46f, 62f, 7f, imageRadius = 0.9f, paperRadius = 2.6f, surface = InstantSurface.GLOSSY)),
    // 方形 SQ：72×86，画面 62×62。
    SQUARE(InstantSpec(72f, 86f, 62f, 62f, 7f, imageRadius = 0.9f, paperRadius = 2.6f, surface = InstantSurface.GLOSSY)),
    // 宽幅：108×86，画面 99×62。
    WIDE(InstantSpec(108f, 86f, 99f, 62f, 7f, imageRadius = 0.9f, paperRadius = 2.6f, surface = InstantSurface.GLOSSY)),
    // Spectra / Image 宽幅：102×103，画面 91×73。
    SPECTRA(InstantSpec(102f, 103f, 91f, 73f, 7f)),
    // 撕拉片：108×85，画面 95×73。
    PEEL(InstantSpec(108f, 85f, 95f, 73f, 6f, paperRadius = 0.3f, surface = InstantSurface.PEEL)),
    // 8×10 大画幅：216×274，画面 190×241。
    LARGE(InstantSpec(216f, 274f, 190f, 241f, 12f, paperRadius = 0.5f)),
}

/** "实物"模式下相纸底下的扫描台。 */
enum class InstantBed(val title: String, val color: PaperColor) {
    WHITE("白色扫描台", PaperColor(0xF1F1EF)),
    GRAY("浅灰", PaperColor(0xC9CACB)),
    DARK("深色", PaperColor(0x18181A)),
}

/** 即显胶片的几种色调。 */
enum class InstantStock(val title: String) {
    CLASSIC("经典"), SX70("柔和"), BOLD("浓郁"), CLEAR("清透"), MONO("黑白"), EXPIRED("过期");

    val color: ColorParams
        get() = ColorParams().apply {
            when (this@InstantStock) {
                // 偏暖、发灰，黑位抬起来，暗部带一点青。
                CLASSIC -> {
                    contrast = 0.08f; fade = 0.38f; saturation = -0.14f; temperature = 0.12f; highlights = -0.2f
                    shadowTint = V3(-0.022f, 0.014f, 0.03f); highlightTint = V3(0.04f, 0.02f, -0.03f)
                }
                // 更软、更淡，整体像蒙了一层奶油。
                SX70 -> {
                    contrast = -0.22f; fade = 0.32f; saturation = -0.22f; temperature = 0.07f; tint = 0.04f
                    brightness = 0.08f
                    shadowTint = V3(0f, 0.012f, 0.022f); highlightTint = V3(0.03f, 0.022f, 0f)
                }
                // 反差大、颜色重，暗部偏蓝。
                BOLD -> {
                    contrast = 0.32f; saturation = 0.14f; fade = 0.14f; temperature = 0.08f; shadows = -0.12f
                    shadowTint = V3(-0.022f, 0f, 0.034f); highlightTint = V3(0.034f, 0.012f, -0.022f)
                }
                // 干净通透，略偏冷偏绿。
                CLEAR -> {
                    contrast = 0.18f; saturation = 0.02f; vibrance = 0.1f; temperature = -0.05f; tint = -0.16f
                    exposure = 0.04f; fade = 0.1f
                    shadowTint = V3(-0.012f, 0.016f, 0.012f)
                }
                // 黑白，带一点暖调的相纸底色。
                MONO -> {
                    mono = true; monoWeights = V3(0.32f, 0.54f, 0.14f); contrast = 0.22f; fade = 0.2f
                    shadowTint = V3(0.012f, 0.006f, 0f); highlightTint = V3(0.03f, 0.016f, -0.02f)
                }
                // 过期相纸：发灰、偏洋红偏黄，暗部发紫。
                EXPIRED -> {
                    contrast = -0.16f; fade = 0.55f; saturation = -0.26f; temperature = 0.2f; tint = 0.3f
                    shadowTint = V3(0.03f, -0.004f, 0.06f); highlightTint = V3(0.05f, 0.026f, -0.04f)
                }
            }
        }

    /** 四角压暗。 */
    val vignette: Float
        get() = when (this) {
            CLASSIC -> 0.2f; SX70 -> 0.12f; BOLD -> 0.28f; CLEAR -> 0.06f; MONO -> 0.22f; EXPIRED -> 0.32f
        }

    /** 高光的柔光。 */
    val bloom: Float
        get() = when (this) {
            CLASSIC -> 0.12f; SX70 -> 0.22f; EXPIRED -> 0.16f; else -> 0f
        }

    /** 把一张（已经裁好的）画面冲成这种色调。 */
    fun develop(shot: Bitmap, intensity: Float): Bitmap =
        if (intensity <= 0f) shot else ColorFx.apply(shot, Look(color, vignette, bloom), intensity, mixLast = true)
}

object InstantPaper {
    val white = PaperColor(0xFBFAF6)
    val cream = PaperColor(0xF3EADB)
    val black = PaperColor(0x171717)
    val all = listOf(
        white, cream, black,
        PaperColor(0xF6D6DA), PaperColor(0xF8ECC2), PaperColor(0xD4EBDC), PaperColor(0xCFE3F3), PaperColor(0xDDD6F0),
    )
}

/** 面板上的一个选项：一种相纸规格，加上是不是横过来用。 */
class InstantPreset(val id: String, val title: String, val format: InstantFormat, val rotated: Boolean = false) {
    companion object {
        val all = listOf(
            InstantPreset("polaroid", "宝丽来方形", InstantFormat.POLAROID),
            InstantPreset("go", "Go 小方", InstantFormat.GO),
            InstantPreset("mini", "mini 竖版", InstantFormat.MINI),
            InstantPreset("miniL", "mini 横版", InstantFormat.MINI, rotated = true),
            InstantPreset("square", "方形 SQ", InstantFormat.SQUARE),
            InstantPreset("wide", "宽幅 wide", InstantFormat.WIDE),
            InstantPreset("wideP", "wide 竖版", InstantFormat.WIDE, rotated = true),
            InstantPreset("spectra", "Spectra 宽幅", InstantFormat.SPECTRA),
            InstantPreset("peel", "撕拉片", InstantFormat.PEEL),
            InstantPreset("peelP", "撕拉片 竖版", InstantFormat.PEEL, rotated = true),
            InstantPreset("large", "大画幅 8×10", InstantFormat.LARGE),
        )
    }
}

/**
 * 拍立得：按相纸比例裁切、加相纸边、套即显胶片的颜色。所有尺寸都从画面宽度按毫米比例换算，
 * 预览和原图导出一样。相纸上不加颗粒。
 */
@Serializable
data class InstantParams(
    val format: InstantFormat = InstantFormat.NONE,
    /** 相纸横过来用：写字的宽边转到右侧。 */
    val rotated: Boolean = false,
    val stock: InstantStock = InstantStock.CLASSIC,
    /** 色调的强度，0...1。 */
    val intensity: Float = 1f,
    val paper: PaperColor = InstantPaper.white,
    /** 取景位置，-1...1：照片比画面宽时左右移，比画面高时上下移（正数 = 往右 / 往下）。 */
    val shift: Float = 0f,
    /** 写在宽边上的字。 */
    val caption: String = "",
    /** 相纸四周留一圈底色，带一点投影。 */
    val shadow: Boolean = false,
    /** 实物：像一张真的照片平放在扫描仪上扫出来的样子。 */
    val real: Boolean = false,
    val bed: InstantBed = InstantBed.WHITE,
) {
    val isIdentity get() = format == InstantFormat.NONE

    fun apply(src: Bitmap): Bitmap = InstantRender.apply(src, this)

    companion object {
        /** 开投影时相纸后面的底色。 */
        val desk = PaperColor(0xE4E1DB)
    }
}

/** 拍立得确认后的一步：画布大小变了。 */
class InstantOp(val params: InstantParams) : EditOp {
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
    override val changesCanvas: Boolean get() = true
}
