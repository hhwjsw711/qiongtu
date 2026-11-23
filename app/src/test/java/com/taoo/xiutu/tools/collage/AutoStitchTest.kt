package com.taoo.xiutu.tools.collage

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * 自动拼图：用一张合成的长"聊天记录"切成几张有重叠、带固定标题栏和输入框的截图，
 * 拼回来要和原来的一模一样（第一张从第 0 行开始，带着标题栏）。
 */
class AutoStitchTest {
    private val w = 360
    private val h = 800
    private val header = 120
    private val footer = 100
    private val content = h - header - footer

    /** 一张图：ARGB 像素，按行存。 */
    private class Img(val width: Int, val height: Int, val px: IntArray) {
        fun row(y: Int, out: IntArray) = System.arraycopy(px, y * width, out, 0, width)
    }

    private fun gray(v: Int): Int {
        val c = v.coerceIn(0, 255)
        return (0xFF shl 24) or (c shl 16) or (c shl 8) or c
    }

    /** 滚动的内容：一行行"消息气泡"，每条位置、长度、颜色都不一样，中间隔着空白。 */
    private fun longContent(rows: Int, seed: Long): Img {
        val rnd = Random(seed)
        val px = IntArray(w * rows) { gray(245) }
        var y = 8
        while (y < rows) {
            val lines = 1 + rnd.nextInt(3)
            val bubbleH = lines * 22 + 12
            val left = rnd.nextBoolean()
            val bw = 120 + rnd.nextInt(200)
            val x0 = if (left) 12 else w - 12 - bw
            val bg = 180 + rnd.nextInt(60)
            for (r in 0 until bubbleH) {
                val yy = y + r
                if (yy >= rows) break
                for (x in x0 until x0 + bw) px[yy * w + x] = gray(bg)
            }
            // 气泡里的"字"：一笔一笔的深色小块
            for (l in 0 until lines) {
                var x = x0 + 8
                while (x < x0 + bw - 14) {
                    val gw = 4 + rnd.nextInt(10)
                    val top = y + 6 + l * 22 + rnd.nextInt(4)
                    val gh = 10 + rnd.nextInt(8)
                    val ink = rnd.nextInt(90)
                    for (r in top until top + gh) {
                        if (r >= rows) break
                        for (xx in x until minOf(x + gw, x0 + bw - 6)) px[r * w + xx] = gray(ink)
                    }
                    x += gw + 2 + rnd.nextInt(6)
                }
            }
            y += bubbleH + 10 + rnd.nextInt(20)
        }
        return Img(w, rows, px)
    }

    /** 固定的标题栏 / 输入框：几块颜色；clock 不为空时在状态栏画一个每张都不一样的"时间"。 */
    private fun band(rows: Int, base: Int, clock: Int?): Img {
        val px = IntArray(w * rows) { gray(base) }
        for (r in rows / 3 until rows * 2 / 3) for (x in 40 until 200) px[r * w + x] = gray(base - 80)
        if (clock != null) for (r in 10 until 15) for (x in 150 until 210) px[r * w + x] = gray((clock * 37) % 200)
        return Img(w, rows, px)
    }

    /** 屏幕上显示内容的第 offset 行起，带上标题栏和输入框。 */
    private fun screenshot(long: Img, offset: Int, clock: Int): Img {
        val top = band(header, 230, clock)
        val bottom = band(footer, 210, null)
        val px = IntArray(w * h)
        System.arraycopy(top.px, 0, px, 0, w * header)
        System.arraycopy(long.px, offset * w, px, header * w, w * content)
        System.arraycopy(bottom.px, 0, px, (h - footer) * w, w * footer)
        return Img(w, h, px)
    }

    private fun signature(img: Img) = AutoStitch.Signature.of(img.width, img.height) { y, out -> img.row(y, out) }

    /** 按拼法把截图接起来。 */
    private fun assemble(shots: List<Img>, plan: AutoStitch.Plan): Img {
        val px = IntArray(plan.width * plan.height)
        var y = 0
        for (p in plan.pieces) {
            System.arraycopy(shots[p.index].px, p.from * w, px, y * w, p.rows * w)
            y += p.rows
        }
        return Img(plan.width, plan.height, px)
    }

    /** 应该拼出来的样子：第一张的标题栏 + 内容从 0 到最后一屏 + 输入框。 */
    private fun expected(long: Img, lastOffset: Int, clock: Int): Img {
        val total = header + lastOffset + content + footer
        val px = IntArray(w * total)
        System.arraycopy(band(header, 230, clock).px, 0, px, 0, w * header)
        System.arraycopy(long.px, 0, px, header * w, w * (lastOffset + content))
        System.arraycopy(band(footer, 210, null).px, 0, px, (header + lastOffset + content) * w, w * footer)
        return Img(w, total, px)
    }

    private fun check(shots: List<Img>, long: Img, lastOffset: Int, firstClock: Int) {
        val plan = AutoStitch.plan(shots.map(::signature))
        assertNotNull(plan)
        plan!!
        assertEquals(0, plan.unmatched)
        assertEquals("第一张从第 0 行开始", 0, plan.pieces.first().from)
        val want = expected(long, lastOffset, firstClock)
        assertEquals("拼好的高度", want.height, plan.height)
        val got = assemble(shots, plan)
        assertTrue("拼好的像素和原图一样", want.px.contentEquals(got.px))
    }

    @Test
    fun scrollDown() {
        val offsets = listOf(0, 400, 750, 1200, 1530)
        val long = longContent(offsets.last() + content, 7)
        val shots = offsets.mapIndexed { i, o -> screenshot(long, o, i + 1) }
        check(shots, long, offsets.last(), 1)
    }

    @Test
    fun scrollUpIsReversed() {
        // 往上翻着截：时间顺序是从下往上，拼出来仍然是从上往下。
        val offsets = listOf(1100, 700, 330, 0)
        val long = longContent(offsets.first() + content, 11)
        val shots = offsets.mapIndexed { i, o -> screenshot(long, o, i + 1) }
        // 反过来后第一张是最上面那一屏（时间上最后截的，clock = 4）
        check(shots, long, offsets.first(), offsets.size)
    }

    @Test
    fun duplicateShotIsSkipped() {
        val offsets = listOf(0, 0, 450, 900)
        val long = longContent(offsets.last() + content, 3)
        val shots = offsets.mapIndexed { i, o -> screenshot(long, o, 1) }
        check(shots, long, offsets.last(), 1)
    }

    @Test
    fun unrelatedShotsStillConcatenate() {
        val a = longContent(content, 1)
        val b = longContent(content, 2)
        val shots = listOf(screenshot(a, 0, 1), screenshot(b, 0, 2))
        val plan = AutoStitch.plan(shots.map(::signature))!!
        assertEquals(1, plan.unmatched)
        assertEquals(0, plan.pieces.first().from)
        // 对不上的整段内容接上去：标题栏 + 两段内容 + 输入框。
        // 两张内容最上面恰好都是几行空白时，这几行会被当成标题栏的一部分，所以允许少几行。
        assertTrue(plan.height in (header + content * 2 + footer - 20)..(header + content * 2 + footer))
    }

    @Test
    fun noisyShotsGiveSameCut() {
        // 截图存成 JPEG 时每个像素会有一点点误差：接缝位置要和没误差时一样。
        val offsets = listOf(0, 380, 820, 1210)
        val long = longContent(offsets.last() + content, 5)
        val clean = offsets.mapIndexed { i, o -> screenshot(long, o, i + 1) }
        val rnd = Random(42)
        val noisy = clean.map { img ->
            Img(w, h, IntArray(img.px.size) { gray((img.px[it] and 0xFF) + rnd.nextInt(7) - 3) })
        }
        val want = AutoStitch.plan(clean.map(::signature))!!
        val got = AutoStitch.plan(noisy.map(::signature))!!
        assertEquals(0, got.unmatched)
        assertEquals(want.height, got.height)
        assertEquals(want.pieces.map { it.index to it.from }, got.pieces.map { it.index to it.from })
    }
}
