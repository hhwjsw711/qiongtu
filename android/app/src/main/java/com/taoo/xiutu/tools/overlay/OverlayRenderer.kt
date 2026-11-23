package com.taoo.xiutu.tools.overlay

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PointF
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.HitSelectable
import com.taoo.xiutu.editor.Tool
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/** 文字 / 贴纸的渲染入口。画布上的预览和最终导出都走这里，保证所见即所得。 */
object OverlayRenderer {
    class Rendered(val bitmap: Bitmap, val k: Float)

    private fun fitted(item: OverlayItem, imageWidth: Float, maxPixel: Float): Pair<OverlayDrawing.Layout, Float>? {
        if (imageWidth <= 0f) return null
        var fontSize = max(2f, item.size * item.scale * imageWidth)
        var layout = OverlayDrawing.layout(item, fontSize) ?: return null
        val m = max(layout.width, layout.height).toFloat()
        var k = 1f
        if (m > maxPixel) {
            k = maxPixel / m
            fontSize *= k
            layout = OverlayDrawing.layout(item, fontSize) ?: return null
        }
        return layout to k
    }

    /**
     * 按"图片宽度 = imageWidth 像素"渲染一项。
     * 位图太大时会按 k 缩小渲染，调用方显示时再除以 k 放大回去。
     */
    fun render(item: OverlayItem, imageWidth: Float, maxPixel: Float = 4096f): Rendered? {
        val (layout, k) = fitted(item, imageWidth, maxPixel) ?: return null
        val bmp = OverlayDrawing.draw(layout) ?: return null
        return Rendered(bmp, k)
    }

    /** 只算大小不画：按图片宽度 = imageWidth 时占多少像素。 */
    fun measure(item: OverlayItem, imageWidth: Float, maxPixel: Float = 4096f): Pair<Float, Float>? {
        val (layout, k) = fitted(item, imageWidth, maxPixel) ?: return null
        return layout.width / k to layout.height / k
    }

    /** 面板上的小样：固定像素大小渲染一项。 */
    fun thumbnail(item: OverlayItem, fontSize: Float): Bitmap? =
        OverlayDrawing.layout(item, fontSize)?.let { OverlayDrawing.draw(it) }

    fun composite(items: List<OverlayItem>, over: Bitmap): Bitmap {
        if (items.isEmpty()) return over
        val out = over.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val w = out.width.toFloat()
        val h = out.height.toFloat()
        for (item in items) {
            val r = render(item, w) ?: continue
            canvas.save()
            canvas.translate(item.cx * w, item.cy * h)
            canvas.rotate(Math.toDegrees(item.rotation.toDouble()).toFloat())
            canvas.scale(1f / r.k, 1f / r.k)
            canvas.drawBitmap(r.bitmap, -r.bitmap.width / 2f, -r.bitmap.height / 2f, paint)
            canvas.restore()
            r.bitmap.recycle()
        }
        return out
    }

    /** 点在哪一项上（从上往下找）。point 是归一化坐标，ratio = 图高 / 图宽。 */
    fun hit(items: List<OverlayItem>, point: PointF, ratio: Float): OverlayItem? {
        // 以画面宽度为单位量距离
        val tx = point.x
        val ty = point.y * ratio
        for (item in items.asReversed()) {
            val (pw, ph) = measure(item, 600f, 1200f) ?: continue
            val w = pw / 600f
            val h = ph / 600f
            val dx = tx - item.cx
            val dy = ty - item.cy * ratio
            val c = cos(item.rotation)
            val s = sin(item.rotation)
            val lx = dx * c + dy * s
            val ly = -dx * s + dy * c
            if (abs(lx) <= w / 2 + 0.015f && abs(ly) <= h / 2 + 0.015f) return item
        }
        return null
    }
}

/** 一步文字 / 贴纸：这次加在画面上的全部项。 */
class OverlayOp(val items: List<OverlayItem>) : EditOp, HitSelectable {
    override fun apply(src: Bitmap): Bitmap = OverlayRenderer.composite(items, src)

    override fun mergesOnReopen(tool: Tool): Boolean = tool == Tool.TEXT || tool == Tool.STICKER || tool == Tool.GRAPHIC

    /** 文字、贴纸、形状浮在照片上面：AI 修图 / 美颜只处理下面的照片。 */
    override val floats: Boolean get() = true

    override fun hitTest(point: PointF, ratio: Float): Tool? = OverlayRenderer.hit(items, point, ratio)?.tool

    override fun selectedId(point: PointF, ratio: Float): String? = OverlayRenderer.hit(items, point, ratio)?.id
}
