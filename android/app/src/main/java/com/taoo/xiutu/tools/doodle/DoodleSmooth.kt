package com.taoo.xiutu.tools.doodle

import android.graphics.PointF
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * 涂鸦的"自动圆润"：手指抬起后把这一笔修顺。
 * 画了个圈 → 变成圆 / 椭圆；差不多是直的 → 拉成直线；其余的 → 去掉手抖的小棱角，整体走势不变。
 */
object DoodleSmooth {
    private const val TAU = (2 * PI).toFloat()

    /** points 是归一化坐标（原点左上角），width × height 是画布尺寸（只用比例）。 */
    fun process(points: List<PointF>, width: Int, height: Int): List<PointF> {
        if (points.size < 3 || width <= 0 || height <= 0) return points
        // 换到"长边 = 1"的等比例坐标里算，横竖图的圆都是圆
        val long = max(width, height).toFloat()
        val sx = width / long
        val sy = height / long
        val raw = points.map { PointF(it.x * sx, it.y * sy) }
        val total = length(raw)
        if (total <= 0.015f) return points
        val pts = resample(raw, max(24, min(240, (total / 0.004f).toInt())))

        val out = ellipse(pts, total) ?: straight(pts) ?: smooth(pts)
        return out.map { PointF(it.x / sx, it.y / sy) }
    }

    // MARK: 识别

    /** 首尾接上（或者画过头一点）、各点到中心的距离又比较一致：当成画了一个圈。 */
    private fun ellipse(pts: List<PointF>, total: Float): List<PointF>? {
        val first = pts.first()
        val last = pts.last()
        // 首尾离得近，或者终点回到了起点附近（画过头）
        var closeIndex = pts.size - 1
        if (dist(first, last) > total * 0.2f) {
            closeIndex = (pts.size / 2 until pts.size).firstOrNull { dist(pts[it], first) < total * 0.08f } ?: return null
        }
        val loop = pts.subList(0, closeIndex + 1)
        val x0 = loop.minOf { it.x }
        val x1 = loop.maxOf { it.x }
        val y0 = loop.minOf { it.y }
        val y1 = loop.maxOf { it.y }
        if (x1 - x0 <= 0.01f || y1 - y0 <= 0.01f) return null
        val cx = (x0 + x1) / 2
        val cy = (y0 + y1) / 2
        var rx = (x1 - x0) / 2
        var ry = (y1 - y0) / 2
        // 太扁的不当圈（多半是来回划了一下）
        if (min(rx, ry) / max(rx, ry) <= 0.28f) return null
        // 各点的"椭圆半径"离 1 有多远
        val errors = loop.map { abs(hypot((it.x - cx) / rx, (it.y - cy) / ry) - 1) }
        if (errors.average() >= 0.16 || errors.max() >= 0.45f) return null
        // 绕过的角度要接近一整圈，不然是一段弧线
        var swept = 0f
        for (i in 1 until loop.size) {
            val a0 = atan2(loop[i - 1].y - cy, loop[i - 1].x - cx)
            val a1 = atan2(loop[i].y - cy, loop[i].x - cx)
            var d = a1 - a0
            if (d > PI) d -= TAU
            if (d < -PI) d += TAU
            swept += d
        }
        if (abs(swept) <= 1.7f * PI.toFloat()) return null
        // 长宽差不多 → 正圆
        if (min(rx, ry) / max(rx, ry) > 0.85f) {
            val r = (rx + ry) / 2
            rx = r
            ry = r
        }
        val start = atan2((first.y - cy) / ry, (first.x - cx) / rx)
        val dir = if (swept >= 0) 1f else -1f
        val n = 96
        return (0..n).map { i ->
            val a = start + dir * i / n * TAU
            PointF(cx + cos(a) * rx, cy + sin(a) * ry)
        }
    }

    /** 每个点离首尾连线都很近：拉成直线。 */
    private fun straight(pts: List<PointF>): List<PointF>? {
        val a = pts.first()
        val b = pts.last()
        val chord = dist(a, b)
        if (chord <= 0.02f) return null
        var worst = 0f
        for (p in pts) worst = max(worst, abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / chord)
        return if (worst / chord < 0.045f) listOf(a, b) else null
    }

    /** 来回几遍滑动平均：小抖动和小棱角没了，大的拐弯还在。首尾不动。 */
    private fun smooth(pts: List<PointF>): List<PointF> {
        var cur = pts
        val k = 3
        repeat(3) {
            val next = cur.toMutableList()
            for (i in 1 until cur.size - 1) {
                val lo = max(0, i - k)
                val hi = min(cur.size - 1, i + k)
                var x = 0f
                var y = 0f
                for (j in lo..hi) {
                    x += cur[j].x
                    y += cur[j].y
                }
                val n = (hi - lo + 1).toFloat()
                next[i] = PointF(x / n, y / n)
            }
            cur = next
        }
        return cur
    }

    // MARK: 小工具

    private fun dist(a: PointF, b: PointF) = hypot(a.x - b.x, a.y - b.y)

    private fun length(pts: List<PointF>): Float {
        var total = 0f
        for (i in 1 until pts.size) total += dist(pts[i - 1], pts[i])
        return total
    }

    /** 沿折线等距取 count 个点。 */
    private fun resample(pts: List<PointF>, count: Int): List<PointF> {
        val total = length(pts)
        if (total <= 0 || count <= 1) return pts
        val step = total / (count - 1)
        val out = arrayListOf(pts[0])
        var want = step
        var travelled = 0f
        for (i in 1 until pts.size) {
            val a = pts[i - 1]
            val b = pts[i]
            val d = dist(a, b)
            if (d <= 0) continue
            while (want <= travelled + d && out.size < count - 1) {
                val u = (want - travelled) / d
                out += PointF(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)
                want += step
            }
            travelled += d
        }
        out += pts[pts.size - 1]
        return out
    }
}
