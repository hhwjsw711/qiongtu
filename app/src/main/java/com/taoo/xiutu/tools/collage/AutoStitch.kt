package com.taoo.xiutu.tools.collage

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 自动拼长图：几张连续滚动的截图（聊天记录、网页），去掉重复的部分接成一张。
 * 1. 每张图顶上的状态栏、标题栏和底下的输入框是固定不动的：找出来，只保留第一张的顶和最后一张的底。
 * 2. 中间的内容是滚动的：找出相邻两张之间滚了多少，后一张只接上新出现的那一截。
 * 这里只算怎么拼（不碰位图），真正读图和画图在 AutoStitchLoader 里。
 */
object AutoStitch {
    /** 拼好的长图里的一段：第 index 张图从第 from 行起的 rows 行。 */
    class Piece(val index: Int, val from: Int, val rows: Int)

    class Plan(
        val width: Int,
        /** 拼好的长图有多高。 */
        val height: Int,
        /** 从上往下依次接上的几段。 */
        val pieces: List<Piece>,
        /** 有几处接缝没对上（直接整截接上去了）。 */
        val unmatched: Int,
    )

    /** 每一行压成这么多个灰度值来比较。 */
    const val COLUMNS = 48

    /** 一张图每一行压成 COLUMNS 个灰度值（0...255）。第 0 行 = 图的最上面一行。 */
    class Signature(val width: Int, val rows: Int, val data: FloatArray) {
        /** 两行的平均差（0...255）。 */
        fun diff(r: Int, other: Signature, s: Int): Float {
            var sum = 0f
            val a = r * COLUMNS
            val b = s * COLUMNS
            for (i in 0 until COLUMNS) sum += abs(data[a + i] - other.data[b + i])
            return sum / COLUMNS
        }

        companion object {
            /** row(y, out) 把第 y 行的 ARGB 像素填进 out（长度 = width）。每一行横着分成 COLUMNS 段，各取平均灰度。 */
            fun of(width: Int, height: Int, row: (y: Int, out: IntArray) -> Unit): Signature {
                val data = FloatArray(height * COLUMNS)
                val line = IntArray(width)
                val bins = IntArray(COLUMNS + 1) { it * width / COLUMNS }
                for (y in 0 until height) {
                    row(y, line)
                    for (c in 0 until COLUMNS) {
                        val x0 = bins[c]
                        val x1 = max(bins[c + 1], x0 + 1).coerceAtMost(width)
                        var sum = 0
                        for (x in x0 until x1) {
                            val p = line[x]
                            sum += (((p shr 16) and 0xFF) * 299 + ((p shr 8) and 0xFF) * 587 + (p and 0xFF) * 114) / 1000
                        }
                        data[y * COLUMNS + c] = sum.toFloat() / max(x1 - x0, 1)
                    }
                }
                return Signature(width, height, data)
            }
        }
    }

    /** sigs 按时间先后排好，每张一样大；自动判断是往下滚还是往上滚。 */
    fun plan(sigs: List<Signature>): Plan? {
        if (sigs.size < 2) return null
        val w = sigs[0].width
        val h = sigs[0].rows
        if (w < 1 || h < 1 || sigs.any { it.width != w || it.rows != h }) return null

        // 固定的头和尾：所有相邻两张都一样的那几行。
        var header = h
        var footer = h
        for (i in 1 until sigs.size) {
            val (top, bottom) = fixedBands(sigs[i - 1], sigs[i])
            header = min(header, top)
            footer = min(footer, bottom)
        }
        if (header + footer > h * 7 / 10) { header = 0; footer = 0 }

        // 方向：第一对正着接和反着接哪个对得更好。
        val forward = overlap(sigs[0], sigs[1], header, footer)
        val backward = overlap(sigs[1], sigs[0], header, footer)
        var order = sigs.indices.toList()
        if (backward != null && backward.second < (forward?.second ?: Float.POSITIVE_INFINITY) * 0.8f) order = order.reversed()

        // 每一张新接上的是内容区下面的多少行。
        val content = h - header - footer
        // 第一张从最上面开始（带着标题栏）。
        val starts = arrayListOf(order[0] to 0)
        var unmatched = 0
        for (k in 1 until order.size) {
            val a = sigs[order[k - 1]]
            val b = sigs[order[k]]
            val m = overlap(a, b, header, footer)
            if (m != null && m.second < 9f) {
                // b 的内容第 r 行 = a 的内容第 r + shift 行；新的从 content - shift 开始。
                if (m.first <= 0) continue // 一模一样的截图，跳过
                starts += order[k] to header + content - m.first
            } else {
                unmatched++
                starts += order[k] to header
            }
        }

        // 每一块从 from 到内容区底部，最后一块带上底部固定的那一截。
        val bodyEnd = h - footer
        val pieces = starts.mapIndexed { i, (index, from) ->
            Piece(index, from, bodyEnd - from + if (i == starts.size - 1) footer else 0)
        }.filter { it.rows > 0 }
        val total = pieces.sumOf { it.rows }
        if (total <= 0) return null
        return Plan(w, total, pieces, unmatched)
    }

    /**
     * 两张截图从上往下、从下往上各有多少行一模一样（固定的标题栏和输入框）。
     * 状态栏的时间会变：允许少数几行不一样，只要整段大多数都一样。
     */
    private fun fixedBands(a: Signature, b: Signature): Pair<Int, Int> {
        val h = a.rows
        fun scan(rows: IntProgression): Int {
            var same = 0
            var last = 0
            for ((n, r) in rows.withIndex()) {
                if (a.diff(r, b, r) < 1.5f) {
                    same++
                    if (same >= (n + 1) * 0.85f) last = n + 1
                }
            }
            return last
        }
        val top = scan(0 until h / 4)
        val bottom = scan((h - h / 4 until h).reversed())
        return top to bottom
    }

    /** b 的内容区接在 a 下面：b 的内容第 r 行 = a 的内容第 r + shift 行。返回最合适的 shift 和平均差。 */
    private fun overlap(a: Signature, b: Signature, header: Int, footer: Int): Pair<Int, Float>? {
        val content = a.rows - header - footer
        if (content <= 40) return null
        val minOverlap = max(content / 8, 24)
        // 先每 4 行取一行粗找，再在附近逐行细找。
        fun score(shift: Int, step: Int): Float {
            val overlapRows = content - shift
            if (overlapRows < minOverlap) return Float.POSITIVE_INFINITY
            var sum = 0f
            var n = 0
            var busy = 0
            var r = 0
            while (r < overlapRows) {
                sum += a.diff(header + r + shift, b, header + r)
                n++
                // 这一行有没有东西（和隔壁行不一样）：全是空白的重叠不算数。
                if (r + step < overlapRows && a.diff(header + r + shift, a, header + r + shift + step) > 4f) busy++
                r += step
            }
            if (n == 0 || busy < 3) return Float.POSITIVE_INFINITY
            return sum / n
        }
        var best = 0 to Float.POSITIVE_INFINITY
        var s = 0
        while (s < content - minOverlap) {
            val e = score(s, 4)
            if (e < best.second) best = s to e
            s += 4
        }
        if (!best.second.isFinite()) return null
        val center = best.first
        var fine = center to Float.POSITIVE_INFINITY
        for (t in max(0, center - 6)..max(0, min(content - minOverlap, center + 6))) {
            val e = score(t, 1)
            if (e < fine.second) fine = t to e
        }
        return if (fine.second.isFinite()) fine else best
    }
}
