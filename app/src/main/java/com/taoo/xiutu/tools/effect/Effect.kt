package com.taoo.xiutu.tools.effect

import android.graphics.Bitmap
import com.taoo.xiutu.ai.AIPreset
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.Tool
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient

/** 特效的分类。 */
enum class EffectCategory(val title: String) {
    LIGHT("光"), BLUR("模糊"), RETRO("复古"), ATMOSPHERE("氛围"), SKY("换天"),
}

/** 一个效果的变体（颜色、方向等）。r/g/b 是主色（0…1）。 */
data class EffectVariant(val title: String, val r: Float = 1f, val g: Float = 1f, val b: Float = 1f)

/** 本机特效。id 和 iOS 的 rawValue 一样。 */
enum class EffectKind(val id: String, val title: String, val category: EffectCategory) {
    // 光
    BLACK_MIST("blackMist", "黑柔", EffectCategory.LIGHT),
    WHITE_MIST("whiteMist", "白柔", EffectCategory.LIGHT),
    SOFT_FOCUS("softFocus", "柔焦", EffectCategory.LIGHT),
    RIM_LIGHT("rimLight", "轮廓光", EffectCategory.LIGHT),
    SUN_FLARE("sunFlare", "逆光光晕", EffectCategory.LIGHT),
    STARBURST("starburst", "星芒", EffectCategory.LIGHT),
    GOD_RAYS("godRays", "丁达尔光", EffectCategory.LIGHT),
    LIGHT_LEAK("lightLeak", "漏光", EffectCategory.LIGHT),
    RAINBOW("rainbow", "彩虹光", EffectCategory.LIGHT),
    BOKEH_LIGHT("bokehLight", "光斑", EffectCategory.LIGHT),
    LEAF_SHADOW("leafShadow", "树影", EffectCategory.LIGHT),
    BLINDS("blinds", "百叶窗", EffectCategory.LIGHT),

    // 模糊
    BG_BLUR("bgBlur", "背景虚化", EffectCategory.BLUR),
    BOKEH("bokeh", "焦外光斑", EffectCategory.BLUR),
    DEFOCUS("defocus", "失焦", EffectCategory.BLUR),
    MOTION_BLUR("motionBlur", "动态模糊", EffectCategory.BLUR),
    ZOOM_BLUR("zoomBlur", "放射模糊", EffectCategory.BLUR),
    GHOST("ghost", "拖影", EffectCategory.BLUR),
    LONG_EXPOSURE("longExposure", "长曝光", EffectCategory.BLUR),
    GAUSSIAN("gaussian", "高斯模糊", EffectCategory.BLUR),

    // 复古
    VHS("vhs", "录像带", EffectCategory.RETRO),
    LOW_PIXEL("lowPixel", "低像素", EffectCategory.RETRO),
    LED("led", "电子屏", EffectCategory.RETRO),
    NEON("neon", "霓虹描边", EffectCategory.RETRO),
    GLITCH("glitch", "故障", EffectCategory.RETRO),
    CRT("crt", "老电视", EffectCategory.RETRO),
    VAPORWAVE("vaporwave", "蒸汽波", EffectCategory.RETRO),
    HALFTONE("halftone", "半调网点", EffectCategory.RETRO),
    LOFI("lofi", "低保真", EffectCategory.RETRO),

    // 氛围
    GOLD_GLITTER("goldGlitter", "金粉闪光", EffectCategory.ATMOSPHERE),
    TWINKLE("twinkle", "星星闪光", EffectCategory.ATMOSPHERE),
    SNOW("snow", "雪花", EffectCategory.ATMOSPHERE),
    COLOR_SNOW("colorSnow", "彩色雪花", EffectCategory.ATMOSPHERE),
    PETALS("petals", "樱花飘落", EffectCategory.ATMOSPHERE),
    LEAVES("leaves", "落叶", EffectCategory.ATMOSPHERE),
    CONFETTI("confetti", "礼花彩带", EffectCategory.ATMOSPHERE),
    HEARTS("hearts", "爱心", EffectCategory.ATMOSPHERE),
    BUBBLES("bubbles", "气泡", EffectCategory.ATMOSPHERE),
    FIREFLIES("fireflies", "萤火", EffectCategory.ATMOSPHERE),
    RAIN("rain", "雨丝", EffectCategory.ATMOSPHERE);

    /** 没有主体蒙版就做不了。 */
    val needsMask: Boolean get() = this == RIM_LIGHT || this == BG_BLUR || this == BOKEH

    /** 有主体蒙版时会用上（主体保持清晰），没有也能做。 */
    val usesMask: Boolean get() = needsMask || this == MOTION_BLUR || this == ZOOM_BLUR || this == GHOST || this == LONG_EXPOSURE

    /** 位置是随机的，可以"换一换"。 */
    val shuffles: Boolean
        get() = category == EffectCategory.ATMOSPHERE || this == GLITCH || this == BOKEH_LIGHT || this == LEAF_SHADOW ||
            this == GOD_RAYS || this == RAINBOW || this == STARBURST

    val defaultStrength: Float
        get() = when (this) {
            RIM_LIGHT -> 0.8f
            GAUSSIAN, DEFOCUS -> 0.5f
            else -> 0.7f
        }

    val variants: List<EffectVariant>
        get() = when (this) {
            RIM_LIGHT -> listOf(
                EffectVariant("白", 1f, 1f, 1f),
                EffectVariant("暖", 1f, 0.72f, 0.38f),
                EffectVariant("冷", 0.55f, 0.78f, 1f),
                EffectVariant("粉", 1f, 0.55f, 0.78f),
                EffectVariant("紫", 0.72f, 0.5f, 1f),
            )
            SUN_FLARE -> listOf(EffectVariant("暖阳", 1f, 0.78f, 0.48f), EffectVariant("白光", 1f, 0.97f, 0.92f))
            STARBURST -> listOf(EffectVariant("四芒"), EffectVariant("六芒"), EffectVariant("八芒"))
            GOD_RAYS -> listOf(EffectVariant("左上", 1f, 0.86f, 0.6f), EffectVariant("右上", 1f, 0.86f, 0.6f))
            LIGHT_LEAK -> listOf(
                EffectVariant("暖橙", 1f, 0.45f, 0.12f),
                EffectVariant("玫红", 1f, 0.2f, 0.35f),
                EffectVariant("蓝紫", 0.45f, 0.3f, 1f),
                EffectVariant("青绿", 0.15f, 0.85f, 0.7f),
            )
            BOKEH_LIGHT -> listOf(
                EffectVariant("暖", 1f, 0.78f, 0.45f),
                EffectVariant("冷", 0.6f, 0.8f, 1f),
                EffectVariant("彩"),
            )
            NEON -> listOf(
                EffectVariant("粉", 1f, 0.25f, 0.75f),
                EffectVariant("青", 0.2f, 0.95f, 1f),
                EffectVariant("紫", 0.65f, 0.35f, 1f),
                EffectVariant("绿", 0.35f, 1f, 0.45f),
            )
            MOTION_BLUR -> listOf(EffectVariant("横向"), EffectVariant("竖向"))
            else -> emptyList()
        }

    companion object {
        private val byID = entries.associateBy { it.id }
        fun by(id: String): EffectKind? = byID[id]
        fun list(category: EffectCategory): List<EffectKind> = entries.filter { it.category == category }
    }
}

/**
 * 一步特效。参数全是相对值，预览和原图一样；随机的东西由 seed 决定。
 * mask 是进工具时对当时画面算好的主体蒙版（不透明灰度图，白 = 主体），比较时按引用。
 */
@Serializable
data class EffectParams(
    val id: String = "",
    val strength: Float = 0.7f,
    val variant: Int = 0,
    val seed: Long = 7,
    /** 随机度 0.01…1：粒子、光斑、光束的大小、亮度、角度差别有多大。0.5 = 默认。 */
    val chaos: Float = 0.5f,
    /** 蒙版不存进处理步骤：套到别的照片上时按那张照片重新算。 */
    @Transient val mask: Bitmap? = null,
) {
    val kind: EffectKind? get() = EffectKind.by(id)

    val isIdentity: Boolean
        get() {
            val k = kind ?: return true
            if (strength <= 0.001f) return true
            return k.needsMask && mask == null
        }

    /** 除了蒙版以外都一样。 */
    fun sameSettings(o: EffectParams) = id == o.id && strength == o.strength && variant == o.variant && seed == o.seed && chaos == o.chaos

    fun apply(src: Bitmap): Bitmap {
        val k = kind ?: return src
        if (isIdentity || src.width < 2 || src.height < 2) return src
        val vs = k.variants
        val v = if (vs.isEmpty()) EffectVariant("") else vs[variant.coerceIn(0, vs.size - 1)]
        return EffectRender.render(k, src, strength.coerceIn(0f, 1f), v, variant, seed, chaos, if (k.usesMask) mask else null)
    }
}

class EffectOp(val params: EffectParams) : EditOp {
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
    override fun reopens(tool: Tool) = tool == Tool.EFFECT
}

/** 换天：交给 AI。colors 是缩略图的渐变色（上 → 下），0xRRGGBB。 */
class EffectSky(val title: String, val symbol: String, val colors: List<Int>, val sky: String) {
    val preset: AIPreset
        get() = AIPreset(
            title = title, symbol = symbol,
            prompt = "把这张照片里的天空换成$sky。只替换天空部分：人物、建筑、树木、地面、水面和整个构图一律保持原样，" +
                "位置、大小和轮廓都不能变，不要裁剪、不要改变画面比例，结果要和原图对齐。" +
                "让画面整体的光线方向、明暗和色调与新的天空协调（地面、建筑和人物身上带上相应的环境光和反光），" +
                "但人物的长相、表情和衣服不变。要真实自然，像实拍的，不要有抠图合成感。",
        )

    companion object {
        val all = listOf(
            EffectSky("晴朗蓝天", "sun.max.fill", listOf(0x2F7BE0, 0x8EC5F5, 0xE6F3FF), "晴朗通透的蓝天，飘着几朵自然的白云"),
            EffectSky("晚霞", "cloud.sun.fill", listOf(0x5B4A9E, 0xE0729A, 0xFFB37A), "绚丽的晚霞，粉紫和橙色的云层铺满天空"),
            EffectSky("夕阳", "sunset.fill", listOf(0xC2462C, 0xF08A3C, 0xFFD27A), "金色的夕阳天空，太阳低垂在地平线附近，暖橙色的光"),
            EffectSky("星空", "sparkles", listOf(0x070B24, 0x1B2552, 0x3A3F7A), "清澈的夜晚星空，满天繁星，深蓝色的夜空（画面整体变成夜景）"),
            EffectSky("银河", "moon.stars.fill", listOf(0x05071A, 0x2A2160, 0x8A6BB8), "璀璨的银河横跨夜空，星星密布（画面整体变成夜景）"),
            EffectSky("超级月亮", "moon.fill", listOf(0x0C1530, 0x2A3A66, 0xC9CFE0), "夜空中一轮又大又亮的满月，月面细节清晰（画面整体变成夜景）"),
            EffectSky("血月", "moon.circle.fill", listOf(0x12060A, 0x4A0E14, 0xB02A22), "夜空中一轮巨大的暗红色血月（画面整体变成夜景）"),
            EffectSky("极光", "wind", listOf(0x061A2A, 0x0F6B5C, 0x6CF2B0), "夜空中舞动的绿色和紫色极光（画面整体变成夜景）"),
            EffectSky("烟花", "sparkle", listOf(0x0A0A1E, 0x3A1A4A, 0xF2A33A), "夜空中绽放的大片绚丽烟花（画面整体变成夜景）"),
            EffectSky("彩虹", "rainbow", listOf(0x6AA8E8, 0xA8D4F2, 0xF4E9C8), "雨后放晴的天空，挂着一道清晰的彩虹"),
            EffectSky("雪夜", "snowflake", listOf(0x1A2438, 0x4A5A78, 0xD8E2F0), "飘着雪的冬夜天空，空中有自然飘落的雪花（画面整体变成雪夜）"),
            EffectSky("粉色梦幻云", "cloud.fill", listOf(0xF6A6C8, 0xFBD3E0, 0xC9D6FF), "梦幻的粉色和淡紫色棉花糖一样的云朵天空"),
        )
    }
}

/** 固定种子的随机数（和 iOS 的 EffectRNG 逐位一样，预览和保存画出来一样）。 */
class EffectRNG(seed: Long, chaos: Float = 0.5f) {
    private var state: ULong = seed.toULong() * 0x9E3779B97F4A7C15uL + 1uL

    /** 随机范围放大 / 缩小的倍数：随机度 0.5 = 1 倍（原来的范围），越低越整齐一致，越高差别越大。 */
    private val spread: Double = chaos.coerceIn(0.01f, 1f).toDouble() * 2

    fun next(): Double {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        z = z xor (z shr 31)
        return (z shr 11).toDouble() / (1uL shl 53).toDouble()
    }

    /** a…b 之间的随机数；随机度改变的是范围的宽窄（中点不变）。原范围全是正数时结果不会小于 a 的三成。 */
    fun range(a: Double, b: Double): Double {
        val mid = (a + b) / 2
        val half = (b - a) / 2 * spread
        var lo = mid - half
        if (a >= 0) lo = maxOf(lo, a * 0.3)
        return lo + (mid + half - lo) * next()
    }
}
