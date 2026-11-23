package com.taoo.xiutu.tools.layers

import android.graphics.Bitmap
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.ml.Cutout
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt

/** 图层的混合方式。mode = null 表示正常叠上去。 */
enum class LayerBlend(val title: String, val mode: BlendMode?) {
    NORMAL("正常", null),
    MULTIPLY("正片叠底", BlendMode.MULTIPLY),
    SCREEN("滤色", BlendMode.SCREEN),
    OVERLAY("叠加", BlendMode.OVERLAY),
    SOFT_LIGHT("柔光", BlendMode.SOFT_LIGHT),
    LIGHTEN("变亮", BlendMode.LIGHTEN),
    DARKEN("变暗", BlendMode.DARKEN),
    COLOR_DODGE("颜色减淡", BlendMode.COLOR_DODGE),
    DIFFERENCE("差值", BlendMode.DIFFERENCE),
    LUMINOSITY("明度", BlendMode.LUMINOSITY),
    COLOR("颜色", BlendMode.COLOR),
}

/** 叠在照片上面的一个图层：一张图，加上它自己的修改、抠图和摆放方式。 */
data class ImageLayer(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    /** 导入时的图。 */
    val original: Bitmap,
    /** 这个图层自己的修改步骤（在单独的编辑器里做的）。 */
    val ops: List<EditOp> = emptyList(),
    /** original 套上 ops 之后的样子；没有修改时就是 original。 */
    val edited: Bitmap,
    /** 抠图蒙版（对应 edited）。 */
    val mask: Bitmap? = null,
    /** 是否去掉背景。 */
    val cutout: Boolean = false,
    /** 抠图边缘的羽化，0...1。 */
    val feather: Float = 0.25f,
    /** 最终贴到画面上的图（抠过图的带透明通道）。 */
    val content: Bitmap,
    /** content 的小图，拖动、缩放时实时预览用。 */
    val preview: Bitmap,
    /** 中心点，归一化坐标，原点在左上角。 */
    val cx: Float = 0.5f,
    val cy: Float = 0.5f,
    /** 图层的宽度占画面宽度的比例。 */
    val width: Float = 0.6f,
    /** 弧度，正数 = 顺时针。 */
    val rotation: Float = 0f,
    val flipped: Boolean = false,
    val opacity: Float = 1f,
    val blend: LayerBlend = LayerBlend.NORMAL,
    val hidden: Boolean = false,
) {
    /** 高 / 宽。 */
    val aspect: Float get() = content.height.toFloat() / max(content.width, 1)

    /**
     * 修改步骤或抠图设置变了之后，重新算 edited / mask / content / preview。耗时，放后台线程调。
     * 第二项 false = 要抠图但没识别到主体（这时 cutout 会被关掉）。
     */
    fun rebuilt(editedChanged: Boolean): Pair<ImageLayer, Boolean> {
        var l = this
        var ok = true
        if (editedChanged) {
            val e = if (ops.isEmpty()) original else runCatching {
                Img.downscale(EditOp.applyAll(ops, original), MAX_SIDE)
            }.onFailure { it.printStackTrace() }.getOrDefault(original)
            l = l.copy(edited = e, mask = null)
        }
        l = if (l.cutout) {
            val m = l.mask ?: Cutout.mask(l.edited)
            val cut = m?.let { Cutout.cut(l.edited, it, l.feather * 0.012f) }
            if (cut != null) l.copy(mask = m, content = cut) else {
                ok = false
                l.copy(mask = m, cutout = false, content = l.edited)
            }
        } else l.copy(content = l.edited)
        return l.copy(preview = makePreview(l.content)) to ok
    }

    companion object {
        /** 导入时最长边缩到多少。 */
        const val MAX_SIDE = 3072
        /** 拖动时用的小图最长边。 */
        const val PREVIEW_SIDE = 1280

        /** 从一张图建一个图层。耗时，放后台线程调。 */
        fun make(name: String, image: Bitmap): ImageLayer {
            val b = Img.downscale(Img.soft(image), MAX_SIDE)
            return ImageLayer(name = name, original = b, edited = b, content = b, preview = makePreview(b))
        }

        private fun makePreview(image: Bitmap): Bitmap = Img.downscale(image, PREVIEW_SIDE)
    }
}

/** 图层合成：在底图上按顺序（从下到上）叠上去。 */
object LayerRender {
    /** usePreview = true 时用每个图层的小图，拖动时才跟得上手。 */
    fun composite(base: Bitmap, layers: List<ImageLayer>, usePreview: Boolean): Bitmap {
        val visible = layers.filter { !it.hidden && it.opacity > 0f }
        if (visible.isEmpty()) return base
        val out = Img.soft(base).copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)
        val w = out.width.toFloat()
        val h = out.height.toFloat()
        for (layer in visible) {
            var image = if (usePreview) layer.preview else layer.content
            val target = layer.width * w
            var scale = target / max(image.width, 1)
            if (!usePreview && scale < 0.6f) {
                // 缩得多时先做一次高质量缩小，直接用矩阵缩会出锯齿和摩尔纹。
                image = Img.downscale(image, max(1, (max(image.width, image.height) * scale).roundToInt()))
                scale = target / max(image.width, 1)
            }
            val m = Matrix()
            m.postTranslate(-image.width / 2f, -image.height / 2f)
            if (layer.flipped) m.postScale(-1f, 1f)
            m.postScale(scale, scale)
            m.postRotate(Math.toDegrees(layer.rotation.toDouble()).toFloat())
            m.postTranslate(layer.cx * w, layer.cy * h)
            val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
            paint.alpha = (layer.opacity.coerceIn(0f, 1f) * 255f).roundToInt()
            layer.blend.mode?.let { paint.blendMode = it }
            canvas.drawBitmap(image, m, paint)
        }
        return out
    }
}

/** 叠在照片上面的一组图层（从下到上），作为编辑历史里的一步。 */
class LayerStack(val layers: List<ImageLayer>) : EditOp {
    val isEmpty get() = layers.isEmpty()

    override fun apply(src: Bitmap): Bitmap = LayerRender.composite(src, layers, usePreview = false)

    /** 图层浮在照片上面：AI 修图 / 美颜只处理下面的照片。 */
    override val floats: Boolean get() = true
}
