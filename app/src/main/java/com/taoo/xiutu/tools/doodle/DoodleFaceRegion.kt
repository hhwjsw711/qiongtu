package com.taoo.xiutu.tools.doodle

import android.graphics.PointF
import com.taoo.xiutu.ml.FaceInfo
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * 妆容笔能画的范围：按识别到的五官算出来，眉笔只落在眉毛上、口红只落在嘴唇上……
 * 结果是归一化坐标（原点左上角）的多边形；每一块的第一圈是外轮廓，后面的是挖掉的洞。
 */
object DoodleFaceRegion {
    class Region(val shapes: List<List<List<PointF>>>, /** 羽化宽度，以图片长边为 1。 */ val feather: Float)

    /** width × height 是图片尺寸（只用比例）。 */
    fun region(brush: DoodleBrush, faces: List<FaceInfo>, width: Int, height: Int): Region {
        if (width <= 0 || height <= 0) return Region(emptyList(), 0f)
        val long = max(width, height).toFloat()
        val sx = width / long
        val sy = height / long
        // 在"长边 = 1"的等比例坐标里算，算完换回去
        fun m(p: List<PointF>) = p.map { PointF(it.x * sx, it.y * sy) }

        val shapes = ArrayList<List<List<PointF>>>()
        var feather = 0f
        for (face in faces) {
            if (!face.hasReliableLandmarks) continue
            val lEye = m(face.leftEye)
            val rEye = m(face.rightEye)
            val lBrow = m(face.leftBrow)
            val rBrow = m(face.rightBrow)
            val outer = m(face.outerLips)
            val inner = m(face.innerLips)
            val contour = m(face.contour)
            val eyeW = maxOf(width(lEye), width(rEye), 0.005f)
            val faceW = max(width(contour), eyeW * 3)
            when (brush) {
                DoodleBrush.BROW -> {
                    for (brow in listOf(lBrow, rBrow)) if (brow.size >= 2) shapes += listOf(band(browLine(brow), eyeW * 0.17f))
                    feather = max(feather, eyeW * 0.08f)
                }
                DoodleBrush.EYELINER -> {
                    // 眼睛一圈：外面放大一点，里面挖掉眼球，只剩睫毛根那一圈
                    for (eye in listOf(lEye, rEye)) if (eye.size >= 3) shapes += listOf(scaled(hull(eye), 1.3f, 1.12f), scaled(hull(eye), 0.82f))
                    feather = max(feather, eyeW * 0.05f)
                }
                DoodleBrush.EYESHADOW -> {
                    // 眼睛和眉毛之间：眼睛的点 + 往眼睛那边收一半的眉毛点，挖掉眼球
                    for ((eye, brow) in listOf(lEye to lBrow, rEye to rBrow)) {
                        if (eye.size < 3 || brow.size < 2) continue
                        val c = centroid(eye)
                        val lifted = brow.map { PointF(c.x + (it.x - c.x) * 0.85f, c.y + (it.y - c.y) * 0.62f) }
                        shapes += listOf(scaled(hull(eye + lifted), 1.12f), scaled(hull(eye), 0.9f))
                    }
                    feather = max(feather, eyeW * 0.14f)
                }
                DoodleBrush.BLUSH -> {
                    // 两边颧骨下面各一块椭圆
                    if (lEye.size < 3 || rEye.size < 3) continue
                    val mouthY = if (outer.isEmpty()) centroid(lEye + rEye).y + eyeW * 1.5f else centroid(outer).y
                    val eyes = listOf(lEye, rEye)
                    for (i in eyes.indices) {
                        val c = centroid(eyes[i])
                        val other = centroid(eyes[1 - i])
                        val outward = if (c.x < other.x) -1f else 1f
                        val center = PointF(c.x + outward * faceW * 0.07f, c.y + (mouthY - c.y) * 0.5f)
                        shapes += listOf(ellipse(center, faceW * 0.15f, faceW * 0.11f))
                    }
                    feather = max(feather, faceW * 0.06f)
                }
                DoodleBrush.LIP -> {
                    if (outer.size < 3) continue
                    val shape = mutableListOf(scaled(hull(outer), 1.04f))
                    // 张着嘴时挖掉嘴里，不涂到牙齿上
                    if (inner.size >= 3 && area(hull(inner)) > area(hull(outer)) * 0.15f) shape += hull(inner)
                    shapes += shape
                    feather = max(feather, eyeW * 0.04f)
                }
                DoodleBrush.GLOW -> {
                    // 整张脸：下颌轮廓 + 往上抬到额头的眉毛
                    if (contour.size < 3) continue
                    val up = (lBrow + rBrow).map { PointF(it.x, it.y - faceW * 0.22f) }
                    shapes += listOf(hull(contour + up))
                    feather = max(feather, faceW * 0.04f)
                }
                else -> {}
            }
        }
        val back = shapes.map { shape -> shape.map { ring -> ring.map { PointF(it.x / sx, it.y / sy) } } }
        return Region(back, feather)
    }

    // MARK: 几何

    private fun width(pts: List<PointF>): Float = if (pts.isEmpty()) 0f else pts.maxOf { it.x } - pts.minOf { it.x }

    private fun centroid(pts: List<PointF>): PointF {
        if (pts.isEmpty()) return PointF(0f, 0f)
        return PointF(pts.sumOf { it.x.toDouble() }.toFloat() / pts.size, pts.sumOf { it.y.toDouble() }.toFloat() / pts.size)
    }

    /** 以重心为中心放大 / 缩小；widen 额外把左右拉长一点（眼尾要能拉出眼线）。 */
    private fun scaled(pts: List<PointF>, k: Float, widen: Float = 1f): List<PointF> {
        val c = centroid(pts)
        return pts.map { PointF(c.x + (it.x - c.x) * k * widen, c.y + (it.y - c.y) * k) }
    }

    private fun ellipse(c: PointF, rx: Float, ry: Float): List<PointF> = (0 until 32).map { i ->
        val a = i / 32f * 2 * PI.toFloat()
        PointF(c.x + cos(a) * rx, c.y + sin(a) * ry)
    }

    internal fun area(pts: List<PointF>): Float {
        if (pts.size < 3) return 0f
        var s = 0f
        for (i in pts.indices) {
            val a = pts[i]
            val b = pts[(i + 1) % pts.size]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /** 凸包（单调链）。 */
    internal fun hull(input: List<PointF>): List<PointF> {
        val pts = input.sortedWith(compareBy<PointF> { it.x }.thenBy { it.y })
        if (pts.size < 3) return pts
        fun cross(o: PointF, a: PointF, b: PointF) = (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        val lower = ArrayList<PointF>()
        for (p in pts) {
            while (lower.size >= 2 && cross(lower[lower.size - 2], lower[lower.size - 1], p) <= 0) lower.removeAt(lower.size - 1)
            lower += p
        }
        val upper = ArrayList<PointF>()
        for (p in pts.asReversed()) {
            while (upper.size >= 2 && cross(upper[upper.size - 2], upper[upper.size - 1], p) <= 0) upper.removeAt(upper.size - 1)
            upper += p
        }
        return lower.dropLast(1) + upper.dropLast(1)
    }

    /**
     * 眉毛当成一条线。ML Kit 给的是上沿 + 倒过来的下沿（一圈轮廓）：上下两半按 x 排好、两两取中点，得到眉毛的中线；
     * 点数对不上时直接按 x 排好当成一条线。
     */
    internal fun browLine(brow: List<PointF>): List<PointF> {
        if (brow.size >= 4 && brow.size % 2 == 0) {
            val half = brow.size / 2
            val top = brow.subList(0, half).sortedBy { it.x }
            val bottom = brow.subList(half, brow.size).sortedBy { it.x }
            return top.indices.map { PointF((top[it].x + bottom[it].x) / 2, (top[it].y + bottom[it].y) / 2) }
        }
        return brow.sortedBy { it.x }
    }

    /** 沿一条折线两边各让出 half 宽的带子（眉毛用；两头收成圆的）。 */
    internal fun band(line: List<PointF>, half: Float): List<PointF> {
        val pts = line.sortedBy { it.x }
        val left = ArrayList<PointF>()
        val right = ArrayList<PointF>()
        for (i in pts.indices) {
            val a = pts[max(0, i - 1)]
            val b = pts[min(pts.size - 1, i + 1)]
            val dx = b.x - a.x
            val dy = b.y - a.y
            val len = max(hypot(dx, dy), 1e-6f)
            val nx = -dy / len * half
            val ny = dx / len * half
            left += PointF(pts[i].x + nx, pts[i].y + ny)
            right += PointF(pts[i].x - nx, pts[i].y - ny)
        }
        // 两头各补半圈：从这一侧绕过线头转到另一侧
        fun cap(c: PointF, from: Float) = (1 until 6).map { i ->
            val a = from - i / 6f * PI.toFloat()
            PointF(c.x + cos(a) * half, c.y + sin(a) * half)
        }
        val n = pts.size
        val endDir = atan2(pts[n - 1].y - pts[max(0, n - 2)].y, pts[n - 1].x - pts[max(0, n - 2)].x)
        val startDir = atan2(pts[min(1, n - 1)].y - pts[0].y, pts[min(1, n - 1)].x - pts[0].x)
        return left + cap(pts[n - 1], endDir + PI.toFloat() / 2) + right.asReversed() + cap(pts[0], startDir - PI.toFloat() / 2)
    }
}
