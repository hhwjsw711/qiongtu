package com.taoo.xiutu.tools.crop

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import com.taoo.xiutu.editor.EditOp
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin
import kotlinx.serialization.Serializable

/** 裁剪比例。 */
enum class CropAspect(val title: String, val ratio: Float?) {
    FREE("自由", null), ORIGINAL("原始", null),
    R1X1("1:1", 1f), R3X4("3:4", 3f / 4), R4X3("4:3", 4f / 3), R9X16("9:16", 9f / 16), R16X9("16:9", 16f / 9),
    R2X3("2:3", 2f / 3), R3X2("3:2", 3f / 2),
}

/** 归一化矩形，原点左上。 */
@Serializable
data class CropRect(val x: Float = 0f, val y: Float = 0f, val w: Float = 1f, val h: Float = 1f) {
    val maxX get() = x + w
    val maxY get() = y + h
}

/**
 * 裁剪 / 旋转参数。先水平翻转，再顺时针转 quarterTurns 个 90°，再拉直，最后裁剪。
 * straighten 是度数，正数 = 画面顺时针转。rect 相对于旋转翻转之后的画面。
 */
@Serializable
data class CropParams(
    val flip: Boolean = false,
    val quarterTurns: Int = 0,
    val straighten: Float = 0f,
    val rect: CropRect = CropRect(),
) {
    val isIdentity get() = this == CropParams()

    fun rotateClockwise() = copy(
        quarterTurns = (quarterTurns + 1) % 4,
        rect = CropRect(1 - rect.maxY, rect.x, rect.h, rect.w),
    )

    fun flipHorizontal() = copy(
        flip = !flip,
        quarterTurns = (4 - quarterTurns) % 4,
        straighten = -straighten,
        rect = rect.copy(x = 1 - rect.maxX),
    )

    fun flipVertical() = copy(
        flip = !flip,
        quarterTurns = ((2 - quarterTurns) % 4 + 4) % 4,
        straighten = -straighten,
        rect = rect.copy(y = 1 - rect.maxY),
    )

    private val turns get() = ((quarterTurns % 4) + 4) % 4

    /** 旋转翻转之后的画面尺寸。 */
    fun orientedSize(w: Int, h: Int): Pair<Int, Int> = if (turns % 2 == 1) h to w else w to h

    /** 原图像素 → 旋转、翻转、拉直之后的画面像素。 */
    private fun orientMatrix(w: Int, h: Int): Matrix {
        val m = Matrix()
        if (flip) {
            m.postScale(-1f, 1f)
            m.postTranslate(w.toFloat(), 0f)
        }
        if (turns != 0) {
            m.postRotate(90f * turns)
            val r = RectF(0f, 0f, w.toFloat(), h.toFloat())
            m.mapRect(r)
            m.postTranslate(-r.left, -r.top)
        }
        val (ow, oh) = orientedSize(w, h)
        if (abs(straighten) > 0.01f) {
            val a = abs(Math.toRadians(straighten.toDouble()))
            // 放大到转过之后仍然铺满原画框
            val s = (cos(a) + sin(a) * max(ow.toDouble() / oh, oh.toDouble() / ow)).toFloat()
            m.postTranslate(-ow / 2f, -oh / 2f)
            m.postRotate(straighten)
            m.postScale(s, s)
            m.postTranslate(ow / 2f, oh / 2f)
        }
        return m
    }

    private fun render(src: Bitmap, m: Matrix, w: Int, h: Int): Bitmap {
        val out = Bitmap.createBitmap(w.coerceAtLeast(1), h.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(src, m, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        return out
    }

    /** 只做翻转、旋转、拉直，不裁剪。裁剪界面显示的就是这个结果。 */
    fun oriented(src: Bitmap): Bitmap {
        if (!flip && turns == 0 && abs(straighten) <= 0.01f) return src
        val (ow, oh) = orientedSize(src.width, src.height)
        return render(src, orientMatrix(src.width, src.height), ow, oh)
    }

    fun apply(src: Bitmap): Bitmap {
        if (isIdentity) return src
        val (ow, oh) = orientedSize(src.width, src.height)
        var x0 = floor(rect.x * ow + 1e-3f).coerceIn(0f, ow.toFloat())
        var y0 = floor(rect.y * oh + 1e-3f).coerceIn(0f, oh.toFloat())
        var x1 = ceil(rect.maxX * ow - 1e-3f).coerceIn(0f, ow.toFloat())
        var y1 = ceil(rect.maxY * oh - 1e-3f).coerceIn(0f, oh.toFloat())
        if (x1 - x0 < 1 || y1 - y0 < 1) { x0 = 0f; y0 = 0f; x1 = ow.toFloat(); y1 = oh.toFloat() }
        val cw = (x1 - x0).toInt()
        val ch = (y1 - y0).toInt()
        // 只裁剪：直接取一块
        if (!flip && turns == 0 && abs(straighten) <= 0.01f) {
            if (cw == src.width && ch == src.height) return src
            return Bitmap.createBitmap(src, x0.toInt(), y0.toInt(), cw, ch)
        }
        // 旋转、拉直、裁剪一次画完，不出中间大图
        val m = orientMatrix(src.width, src.height)
        m.postTranslate(-x0, -y0)
        return render(src, m, cw, ch)
    }
}

/** 裁剪这一步。 */
class CropOp(val params: CropParams) : EditOp {
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
    override val changesCanvas: Boolean get() = true
}
