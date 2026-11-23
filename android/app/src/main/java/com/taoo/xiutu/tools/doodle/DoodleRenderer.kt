package com.taoo.xiutu.tools.doodle

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.DashPathEffect
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.util.LruCache
import com.taoo.xiutu.gpu.Gpu
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** 固定种子的随机数：同一笔在预览和导出时散布得一模一样（和 iOS 同一个算法）。 */
class DoodleRandom(seed: Long) {
    private var state: ULong = seed.toULong() + 0x9E3779B97F4A7C15uL

    fun next(): ULong {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        return z xor (z shr 31)
    }

    /** 0..<1 */
    fun unit(): Float = ((next() shr 11).toDouble() / (1L shl 53).toDouble()).toFloat()

    fun range(a: Float, b: Float) = a + (b - a) * unit()

    /** 近似正态分布，标准差 1。 */
    fun gauss(): Float {
        val u = max(unit(), 1e-9f)
        val v = unit()
        return sqrt(-2 * ln(u)) * cos(2 * PI.toFloat() * v)
    }
}

/**
 * 把笔画画成位图。只用 Android Canvas，所有尺寸都按画布大小折算，
 * 所以 1600 像素的预览和原图分辨率的导出画出来是同一个样子。坐标原点左上角。
 */
object DoodleRenderer {
    /** 导出时笔画那一层最大画多大（长边像素）。 */
    const val MAX_LAYER_SIDE = 4096f

    fun makeBitmap(width: Int, height: Int): Bitmap? =
        if (width <= 0 || height <= 0) null else runCatching { Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888) }.getOrNull()

    fun clear(b: Bitmap) = b.eraseColor(0)

    /** 所有笔画（聚光除外）画成一层。 */
    fun layer(strokes: List<DoodleStroke>, width: Int, height: Int): Bitmap? {
        val b = makeBitmap(width, height) ?: return null
        val c = Canvas(b)
        for (s in strokes) draw(s, c, width, height)
        return b
    }

    // MARK: 合成

    /** 聚光：整张压暗，只留出圈住的地方。返回压暗用的那一层（小图，边缘在合成时再柔化）。 */
    private fun dimLayer(spots: List<DoodleStroke>, width: Int, height: Int): Bitmap? {
        val k = min(1f, 1024f / max(max(width, height), 1))
        val w = max(1, (width * k).roundToInt())
        val h = max(1, (height * k).roundToInt())
        val holes = ArrayList<RectF>()
        for (s in spots) {
            if (s.points.size < 2) continue
            val a = s.points[0]
            val b = s.points[s.points.size - 1]
            val r = RectF(min(a.x, b.x) * w, min(a.y, b.y) * h, max(a.x, b.x) * w, max(a.y, b.y) * h)
            if (r.width() >= 3 && r.height() >= 3) holes += r
        }
        if (holes.isEmpty()) return null
        val bmp = makeBitmap(w, h) ?: return null
        val c = Canvas(bmp)
        c.drawColor(android.graphics.Color.argb(153, 0, 0, 0))
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT); color = android.graphics.Color.BLACK }
        for (r in holes) c.drawOval(r, p)
        return bmp
    }

    /** 把笔画层叠到图上。layers 按顺序从下往上叠，第二项是这一层整体的不透明度。 */
    fun compose(image: Bitmap, layers: List<Pair<Bitmap, Float>>, spots: List<DoodleStroke>): Bitmap {
        val dim = if (spots.isEmpty()) null else dimLayer(spots, image.width, image.height)
        if (dim == null && layers.isEmpty()) return image
        val out = image.copy(Bitmap.Config.ARGB_8888, true)
        val c = Canvas(out)
        val dst = RectF(0f, 0f, out.width.toFloat(), out.height.toFloat())
        val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
        if (dim != null) {
            // 和 iOS 一样：模糊半径按整张图长边的 1.2% 算（在小图上折算）
            val sigma = max(image.width, image.height) * 0.012f * dim.width / image.width
            val soft = runCatching { Gpu.run { read(blur(upload(dim), sigma * 2.5f)) } }.getOrDefault(dim)
            c.drawBitmap(soft, null, dst, paint)
        }
        for ((b, opacity) in layers) {
            paint.alpha = (opacity.coerceIn(0f, 1f) * 255).roundToInt()
            c.drawBitmap(b, null, dst, paint)
        }
        return out
    }

    // MARK: 几何

    private class Sample(val p: PointF, val angle: Float, val s: Float, val t: Float)

    private fun dist(a: PointF, b: PointF) = hypot(a.x - b.x, a.y - b.y)

    private fun length(pts: List<PointF>): Float {
        var total = 0f
        for (i in 1 until pts.size) total += dist(pts[i - 1], pts[i])
        return total
    }

    /** 把手指经过的点连成顺滑的折线：相邻两点的中点之间用二次曲线过渡。 */
    private fun flatten(raw: List<PointF>, step: Float): Pair<List<PointF>, List<Float>> {
        val n = raw.size
        if (n <= 2) return raw to raw.indices.map { it.toFloat() }
        fun mid(a: PointF, b: PointF) = PointF((a.x + b.x) / 2, (a.y + b.y) / 2)
        val pts = ArrayList<PointF>(n * 4)
        val ts = ArrayList<Float>(n * 4)
        pts += raw[0]; ts += 0f
        var from = mid(raw[0], raw[1])
        pts += from; ts += 0.5f
        for (i in 1 until n - 1) {
            val c = raw[i]
            val to = mid(raw[i], raw[i + 1])
            // 细分多少段只看笔的粗细，不看像素数
            val k = min(64, max(1, ceil((dist(from, c) + dist(c, to)) / max(step, 0.0001f)).toInt()))
            for (j in 1..k) {
                val u = j.toFloat() / k
                val a = (1 - u) * (1 - u)
                val b = 2 * (1 - u) * u
                val d = u * u
                pts += PointF(a * from.x + b * c.x + d * to.x, a * from.y + b * c.y + d * to.y)
                ts += i - 0.5f + u
            }
            from = to
        }
        pts += raw[n - 1]; ts += (n - 1).toFloat()
        return pts to ts
    }

    /** 沿折线每隔 spacing 取一个点。 */
    private fun walk(pts: List<PointF>, ts: List<Float>, spacing: Float): List<Sample> {
        val first = pts.firstOrNull() ?: return emptyList()
        if (pts.size <= 1) return listOf(Sample(first, 0f, 0f, 0f))
        val total = length(pts)
        // 笔画特别长、笔又特别细时也不让点数失控
        val gap = maxOf(spacing, 0.35f, total / 30000)
        val out = ArrayList<Sample>()
        var next = 0f
        var travelled = 0f
        for (i in 1 until pts.size) {
            val a = pts[i - 1]
            val b = pts[i]
            val d = dist(a, b)
            if (d <= 0) continue
            val angle = atan2(b.y - a.y, b.x - a.x)
            while (next <= travelled + d) {
                val u = (next - travelled) / d
                out += Sample(PointF(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u), angle, next, ts[i - 1] + (ts[i] - ts[i - 1]) * u)
                next += gap
            }
            travelled += d
        }
        if (out.isEmpty()) out += Sample(first, 0f, 0f, 0f)
        return out
    }

    /** 折线上离起点 distance 远的那个点。 */
    private fun point(pts: List<PointF>, distance: Float): PointF {
        var last = pts.firstOrNull() ?: return PointF()
        var left = max(distance, 0f)
        for (i in 1 until pts.size) {
            val p = pts[i]
            val d = dist(last, p)
            if (d > 0 && left <= d) {
                val u = left / d
                return PointF(last.x + (p.x - last.x) * u, last.y + (p.y - last.y) * u)
            }
            left -= d
            last = p
        }
        return last
    }

    /** 只保留折线的前 keep 这么长。 */
    private fun trimmed(pts: List<PointF>, keep: Float): List<PointF> {
        val first = pts.firstOrNull() ?: return emptyList()
        val out = arrayListOf(first)
        var left = keep
        for (i in 1 until pts.size) {
            val p = pts[i]
            val last = out.last()
            val d = dist(last, p)
            if (d >= left) {
                if (d > 0) {
                    val u = max(left, 0f) / d
                    out += PointF(last.x + (p.x - last.x) * u, last.y + (p.y - last.y) * u)
                }
                return out
            }
            left -= d
            out += p
        }
        return out
    }

    private fun bounds(pts: List<PointF>): RectF {
        val f = pts.first()
        val r = RectF(f.x, f.y, f.x, f.y)
        for (p in pts) {
            r.left = min(r.left, p.x); r.right = max(r.right, p.x)
            r.top = min(r.top, p.y); r.bottom = max(r.bottom, p.y)
        }
        return r
    }

    // MARK: 画笔状态（相当于 CGContext 的那一套）

    /** CG 的阴影 blur 约等于 2σ；Android 阴影半径换算成 σ = 0.577r + 0.5。 */
    private fun shadowRadius(blur: Float) = max((blur / 2 - 0.5f) / 0.57735f, 0.1f)

    private class Pen(val c: Canvas) {
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        var erase = false
        /** 阴影：blur（CG 的写法）和颜色。 */
        var shadow: Pair<Float, Int>? = null

        fun paint(style: Paint.Style, color: Int): Paint {
            p.reset()
            p.isAntiAlias = true
            p.style = style
            p.color = color
            p.strokeJoin = Paint.Join.ROUND
            shadow?.let { p.setShadowLayer(shadowRadius(it.first), 0f, 0f, it.second) }
            if (erase) p.xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_OUT)
            return p
        }

        fun line(pts: List<PointF>, width: Float, color: Int, cap: Paint.Cap = Paint.Cap.ROUND, dash: FloatArray? = null, phase: Float = 0f) {
            val first = pts.firstOrNull() ?: return
            if (pts.size == 1) {
                c.drawCircle(first.x, first.y, width / 2, paint(Paint.Style.FILL, color))
                return
            }
            val q = paint(Paint.Style.STROKE, color)
            q.strokeWidth = width
            q.strokeCap = cap
            if (dash != null) q.pathEffect = DashPathEffect(dash, phase)
            val path = Path()
            path.moveTo(first.x, first.y)
            for (i in 1 until pts.size) path.lineTo(pts[i].x, pts[i].y)
            c.drawPath(path, q)
        }

        fun circle(center: PointF, radius: Float, color: Int) {
            c.drawCircle(center.x, center.y, radius, paint(Paint.Style.FILL, color))
        }

        fun fill(path: Path, color: Int) = c.drawPath(path, paint(Paint.Style.FILL, color))

        fun fillStroke(path: Path, color: Int, lineWidth: Float) {
            val q = paint(Paint.Style.FILL_AND_STROKE, color)
            q.strokeWidth = lineWidth
            c.drawPath(path, q)
        }
    }

    private fun poly(pts: List<PointF>, close: Boolean = true): Path {
        val path = Path()
        pts.forEachIndexed { i, p -> if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y) }
        if (close) path.close()
        return path
    }

    // MARK: 一笔

    /** 把一笔画进画布。width × height = 画布像素尺寸（对应整张图片）。 */
    fun draw(stroke: DoodleStroke, c: Canvas, width: Int, height: Int) {
        val long = max(width, height).toFloat()
        if (long <= 0 || stroke.points.isEmpty() || stroke.brush == DoodleBrush.SPOT) return
        val w = max(stroke.width * long, 0.6f)
        val raw = ArrayList<PointF>(stroke.points.size)
        for (p in stroke.points) {
            val q = PointF(p.x * width, p.y * height)
            val last = raw.lastOrNull()
            if (last != null && dist(q, last) < 0.05f) continue
            raw += q
        }
        if (raw.isEmpty()) return

        // 只在这一笔附近画：整笔半透明时要开一个临时图层，范围小才快
        val reach = when {
            stroke.brush == DoodleBrush.NEON || stroke.brush == DoodleBrush.NUMBER ||
                stroke.brush == DoodleBrush.ARROW || stroke.brush == DoodleBrush.ARROW_PEN -> w * 5 + 4
            stroke.brush.category == DoodleCategory.PATTERN -> {
                // 图案会被散布出去、也会被放大一点：范围按散布算
                val j = stroke.jitter ?: DoodleJitter()
                w * (1.6f + j.scatter * 1.3f) * (if (stroke.brush == DoodleBrush.SPARKLES) 2.5f else 1f) + 4
            }
            else -> w * 1.7f + 4
        }
        val clip = bounds(raw).apply { inset(-reach, -reach) }
        c.save()
        c.clipRect(clip)
        val pen = Pen(c)
        if (stroke.brush == DoodleBrush.ERASER) {
            pen.erase = true
            pen.line(flatten(raw, w * 0.1f).first, w, android.graphics.Color.BLACK)
            c.restore()
            return
        }
        // 妆容笔：只落在对应的五官上，边缘羽化。范围外一点都不画
        val mask = if (stroke.region.isEmpty()) null else regionMask(stroke, width, height)
        if (stroke.region.isNotEmpty()) {
            if (mask == null || !c.clipRect(mask.first)) {
                c.restore()
                return
            }
        }
        val opacity = stroke.opacity.coerceIn(0f, 1f)
        val layered = opacity < 0.999f || mask != null
        if (layered) c.saveLayerAlpha(clip, (opacity * 255).roundToInt())
        if (stroke.brush.isShape) shape(stroke, raw, w, pen) else freehand(stroke, raw, w, long, pen)
        if (mask != null) c.drawBitmap(mask.second, mask.first.left.toFloat(), mask.first.top.toFloat(), maskPaint)
        if (layered) c.restore()
        c.restore()
    }

    /** 盖蒙版用：只留下蒙版里白的地方。 */
    private val maskPaint = Paint(Paint.FILTER_BITMAP_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN) }

    /** 按笔画种子 + 画布尺寸缓存蒙版，按字节算大小。 */
    private val maskCache = object : LruCache<String, Bitmap>(32 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }

    /** 妆容笔范围的羽化蒙版（不透明 = 能画），只覆盖范围外接矩形那一块。返回画布坐标里的矩形和蒙版。 */
    private fun regionMask(stroke: DoodleStroke, width: Int, height: Int): Pair<Rect, Bitmap>? {
        val long = max(width, height).toFloat()
        val feather = max(stroke.feather * long, 1f)
        val all = stroke.region.flatMap { shape -> shape.flatMap { ring -> ring.map { PointF(it.x * width, it.y * height) } } }
        if (all.isEmpty()) return null
        val box = bounds(all).apply { inset(-feather * 2, -feather * 2) }
        val rect = Rect(kotlin.math.floor(box.left).toInt(), kotlin.math.floor(box.top).toInt(), ceil(box.right).toInt(), ceil(box.bottom).toInt())
        if (!rect.intersect(0, 0, width, height) || rect.width() < 1 || rect.height() < 1) return null
        val key = "${stroke.seed}-${width}x$height"
        maskCache.get(key)?.let { return rect to it }
        val bmp = runCatching { Bitmap.createBitmap(rect.width(), rect.height(), Bitmap.Config.ALPHA_8) }.getOrNull() ?: return null
        val c = Canvas(bmp)
        // 和 iOS 的高斯模糊一样宽：CI 的半径就是 σ，BlurMaskFilter 的半径换算成 σ = 0.577r + 0.5
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            maskFilter = BlurMaskFilter(max((feather - 0.5f) / 0.57735f, 0.5f), BlurMaskFilter.Blur.NORMAL)
        }
        for (shape in stroke.region) {
            val path = Path()
            path.fillType = Path.FillType.EVEN_ODD
            for (ring in shape) {
                if (ring.size < 3) continue
                ring.forEachIndexed { i, p ->
                    val x = p.x * width - rect.left
                    val y = p.y * height - rect.top
                    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                path.close()
            }
            c.drawPath(path, paint)
        }
        maskCache.put(key, bmp)
        return rect to bmp
    }

    /** 实心箭头尖。tip 是尖端，angle 是指向。 */
    private fun arrowHead(pen: Pen, tip: PointF, angle: Float, length: Float, width: Float, color: Int) {
        val ux = cos(angle)
        val uy = sin(angle)
        val back = PointF(tip.x - ux * length, tip.y - uy * length)
        val notch = PointF(tip.x - ux * length * 0.78f, tip.y - uy * length * 0.78f)
        val left = PointF(back.x - uy * width / 2, back.y + ux * width / 2)
        val right = PointF(back.x + uy * width / 2, back.y - ux * width / 2)
        pen.fillStroke(poly(listOf(tip, left, notch, right)), color, max(width * 0.08f, 0.5f))
    }

    /** 边缘发虚的圆点：半径 100 的渐变，每次用矩阵挪到位置、缩放到大小。 */
    private class SoftDab(color: DoodleColor, flow: Float, hardness: Float) {
        val paint: Paint
        private val m = Matrix()
        private val shader: RadialGradient

        init {
            val h = hardness.coerceIn(0f, 0.95f)
            shader = RadialGradient(
                0f, 0f, 100f,
                intArrayOf(color.argb(flow), color.argb(flow), color.argb(flow * 0.32f), color.argb(0f)),
                floatArrayOf(0f, h, h + (1 - h) * 0.5f, 1f),
                Shader.TileMode.CLAMP,
            )
            paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = this@SoftDab.shader }
        }

        fun dab(c: Canvas, at: PointF, radius: Float) {
            val r = max(radius, 0.5f)
            m.setScale(r / 100f, r / 100f)
            m.postTranslate(at.x, at.y)
            shader.setLocalMatrix(m)
            c.drawCircle(at.x, at.y, r, paint)
        }
    }

    // MARK: 手绘的各种笔

    private fun freehand(stroke: DoodleStroke, raw: List<PointF>, w: Float, long: Float, pen: Pen) {
        val color = stroke.color
        val cg = color.argb()
        val rng = DoodleRandom(stroke.seed)
        val line = flatten(raw, w * 0.1f)
        val pts = line.first
        val c = pen.c

        when (stroke.brush) {
            DoodleBrush.PEN -> pen.line(pts, w, cg)

            DoodleBrush.ARROW_PEN -> {
                val total = length(pts)
                val headLength = w * 3.6f
                val headWidth = w * 3.3f
                if (total <= w * 1.2f) {
                    pen.line(pts, w, cg)
                    return
                }
                // 箭头方向看最后一小段的走向，不看最后两个点，免得手一抖箭头就歪
                val tip = pts[pts.size - 1]
                val from = point(pts, max(0f, total - max(headLength, w * 4)))
                val angle = atan2(tip.y - from.y, tip.x - from.x)
                pen.line(trimmed(pts, max(0f, total - headLength * 0.7f)), w, cg)
                arrowHead(pen, tip, angle, min(headLength, total), headWidth, cg)
            }

            DoodleBrush.MARKER -> {
                // 斜口笔头：一小段斜线沿着笔迹扫过去，横着粗、斜着细
                val nx = w * 0.5f * 0.7071f
                val ny = -w * 0.5f * 0.7071f
                if (pts.size == 1) {
                    pen.line(listOf(PointF(pts[0].x - nx, pts[0].y - ny), PointF(pts[0].x + nx, pts[0].y + ny)), w * 0.3f, cg, Paint.Cap.BUTT)
                    return
                }
                val path = Path()
                path.fillType = Path.FillType.WINDING
                for (i in 1 until pts.size) {
                    val a = pts[i - 1]
                    val b = pts[i]
                    // 四个角按同一个绕向排，重叠的地方才不会被镂空
                    val cross = (b.x - a.x) * ny - (b.y - a.y) * nx
                    val quad = listOf(
                        PointF(a.x - nx, a.y - ny), PointF(a.x + nx, a.y + ny),
                        PointF(b.x + nx, b.y + ny), PointF(b.x - nx, b.y - ny),
                    )
                    val q = if (cross >= 0) quad else quad.reversed()
                    path.moveTo(q[0].x, q[0].y)
                    for (j in 1..3) path.lineTo(q[j].x, q[j].y)
                    path.close()
                }
                pen.fill(path, cg)
                pen.line(pts, w * 0.3f, cg, Paint.Cap.BUTT)
            }

            DoodleBrush.HIGHLIGHTER -> pen.line(pts, w, cg, Paint.Cap.BUTT)

            DoodleBrush.PENCIL -> {
                // 三根错开一点的细线，中间随机断开，像铅笔在纸上蹭出来的
                if (pts.size <= 1) {
                    pen.line(pts, w * 0.8f, color.argb(0.8f))
                    return
                }
                val knots = max(2, (length(pts) / (w * 1.6f)).toInt() + 2)
                repeat(3) {
                    val offsets = FloatArray(knots) { rng.range(-0.3f, 0.3f) * w }
                    val moved = ArrayList<PointF>(pts.size)
                    for (i in pts.indices) {
                        val a = pts[max(i - 1, 0)]
                        val b = pts[min(i + 1, pts.size - 1)]
                        val d = max(dist(a, b), 0.0001f)
                        val f = i.toFloat() / (pts.size - 1) * (knots - 1)
                        val k = min(f.toInt(), knots - 2)
                        val o = offsets[k] + (offsets[k + 1] - offsets[k]) * (f - k)
                        moved += PointF(pts[i].x - (b.y - a.y) / d * o, pts[i].y + (b.x - a.x) / d * o)
                    }
                    val dash = floatArrayOf(w * rng.range(2f, 6f), w * rng.range(0.15f, 0.5f), w * rng.range(1.5f, 4f), w * rng.range(0.15f, 0.4f))
                    pen.line(moved, w * 0.46f, color.argb(0.55f), dash = dash, phase = w * rng.range(0f, 4f))
                }
            }

            DoodleBrush.CALLIGRAPHY -> {
                // 划得快就细、慢就粗，起笔收笔带尖
                val factor = FloatArray(raw.size) { 1f }
                var smooth = 1f
                for (i in 1 until raw.size) {
                    val f = (1.35f - 0.55f * dist(raw[i], raw[i - 1]) / w).coerceIn(0.3f, 1.2f)
                    smooth = smooth * 0.65f + f * 0.35f
                    factor[i] = smooth
                }
                if (raw.size > 1) factor[0] = factor[1]
                val total = length(pts)
                val head = min(w * 3, total * 0.25f)
                val tail = min(w * 4, total * 0.3f)
                for (s in walk(pts, line.second, w * 0.12f)) {
                    val i = min(s.t.toInt(), raw.size - 1)
                    val j = min(i + 1, raw.size - 1)
                    var f = factor[i] + (factor[j] - factor[i]) * (s.t - i)
                    if (head > 0 && s.s < head) f *= 0.25f + 0.75f * s.s / head
                    if (tail > 0 && total - s.s < tail) f *= 0.12f + 0.88f * (total - s.s) / tail
                    pen.circle(s.p, max(w * 0.5f * f, 0.3f), cg)
                }
            }

            DoodleBrush.CRAYON -> {
                // 先铺一层淡淡的底色，再叠很多顺着笔迹方向的小短线：边上稀、中间密
                pen.line(pts, w * 0.78f, color.argb(0.38f))
                for (s in walk(pts, line.second, w * 0.11f)) {
                    val ux = cos(s.angle)
                    val uy = sin(s.angle)
                    repeat(6) {
                        val across = (rng.unit() + rng.unit() - 1) * 0.5f * w
                        val along = rng.range(-0.15f, 0.15f) * w
                        val half = rng.range(0.07f, 0.2f) * w
                        val cx = s.p.x + ux * along - uy * across
                        val cy = s.p.y + uy * along + ux * across
                        val q = pen.paint(Paint.Style.STROKE, color.argb(rng.range(0.5f, 1f)))
                        q.strokeCap = Paint.Cap.ROUND
                        q.strokeWidth = max(rng.range(0.08f, 0.17f) * w, 0.4f)
                        c.drawLine(cx - ux * half, cy - uy * half, cx + ux * half, cy + uy * half, q)
                    }
                }
            }

            DoodleBrush.CLOUD -> {
                val dab = SoftDab(color, 0.55f, 0.25f)
                for (s in walk(pts, line.second, w * 0.22f)) {
                    repeat(2) {
                        val cx = s.p.x + rng.range(-0.28f, 0.28f) * w
                        val cy = s.p.y + rng.range(-0.28f, 0.28f) * w
                        dab.dab(c, PointF(cx, cy), rng.range(0.3f, 0.52f) * w)
                    }
                }
            }

            DoodleBrush.SPRAY -> {
                for (s in walk(pts, line.second, w * 0.2f)) {
                    repeat(14) {
                        val cx = s.p.x + rng.gauss() * 0.3f * w
                        val cy = s.p.y + rng.gauss() * 0.3f * w
                        val col = color.argb(rng.range(0.6f, 1f))
                        pen.circle(PointF(cx, cy), max(rng.range(0.018f, 0.045f) * w, 0.35f), col)
                    }
                }
            }

            DoodleBrush.DASHED -> pen.line(pts, w, cg, dash = floatArrayOf(w * 2, w * 2.6f))

            DoodleBrush.RAINBOW -> {
                // 颜色沿着笔迹转一圈色相；转一圈的长度按图片长边算，换分辨率不会变
                val start = java.lang.Long.remainderUnsigned(stroke.seed, 1000L) / 1000f
                val period = long * 0.3f
                val samples = walk(pts, line.second, max(w * 0.25f, 1f))
                if (samples.size <= 1) {
                    pen.line(pts, w, DoodleColor.hue(start).argb())
                    return
                }
                for (i in 1 until samples.size) {
                    pen.line(listOf(samples[i - 1].p, samples[i].p), w, DoodleColor.hue(start + samples[i].s / period).argb())
                }
                val last = pts.last()
                val end = samples.last()
                pen.line(listOf(end.p, last), w, DoodleColor.hue(start + end.s / period).argb())
            }

            DoodleBrush.NEON -> {
                // 先画两遍带光晕的彩色线，再在中间压一根发白的芯
                pen.shadow = w * 1.6f to cg
                pen.line(pts, w, cg)
                pen.line(pts, w * 0.8f, cg)
                pen.shadow = null
                pen.line(pts, w * 0.45f, color.mixed(DoodleColor.white, 0.8f).argb())
            }

            DoodleBrush.EYELINER -> {
                // 起笔渐粗，收笔拉出一个尖；边缘略带一点晕开，不是硬邦邦的实线
                val total = length(pts)
                val head = min(w * 4, total * 0.2f)
                val tail = min(w * 8, total * 0.35f)
                val dab = SoftDab(color, 0.45f, 0.55f)
                for (s in walk(pts, line.second, w * 0.1f)) {
                    var f = 1f
                    if (head > 0 && s.s < head) f *= 0.2f + 0.8f * s.s / head
                    if (tail > 0 && total - s.s < tail) f *= 0.06f + 0.94f * (total - s.s) / tail
                    dab.dab(c, s.p, max(w * 0.6f * f, 0.4f))
                }
            }

            DoodleBrush.BROW, DoodleBrush.EYESHADOW, DoodleBrush.BLUSH, DoodleBrush.LIP, DoodleBrush.GLOW -> {
                // 妆容：边缘发虚的小圆点一个个叠上去，像刷子带着粉扫过
                val (flow, hardness) = when (stroke.brush) {
                    DoodleBrush.BROW -> 0.2f to 0.12f
                    DoodleBrush.EYESHADOW -> 0.08f to 0f
                    DoodleBrush.BLUSH -> 0.06f to 0f
                    DoodleBrush.LIP -> 0.24f to 0.3f
                    else -> 0.07f to 0f
                }
                val dab = SoftDab(color, flow, hardness)
                for (s in walk(pts, line.second, w * 0.15f)) dab.dab(c, s.p, w * 0.5f)
            }

            DoodleBrush.STARS, DoodleBrush.HEARTS, DoodleBrush.SPARKLES, DoodleBrush.BUBBLES,
            DoodleBrush.PETALS, DoodleBrush.LEAVES, DoodleBrush.RAINDROPS, DoodleBrush.SNOWFLAKES, DoodleBrush.NOTES -> {
                val j = stroke.jitter ?: DoodleJitter()
                val copies = max(1, j.count.roundToInt())
                for (s in walk(pts, line.second, w * max(j.spacing, 0.2f))) {
                    repeat(copies) {
                        // 散布：沿着路线和垂直路线两个方向都随机挪开
                        val across = rng.range(-1f, 1f) * j.scatter * w
                        val along = (if (copies > 1) rng.range(-1f, 1f) else rng.range(-0.3f, 0.3f)) * j.scatter * w
                        val center = PointF(
                            s.p.x + cos(s.angle) * along - sin(s.angle) * across,
                            s.p.y + sin(s.angle) * along + cos(s.angle) * across,
                        )
                        val scale = 1 - j.size * rng.unit() * 0.75f + j.size * 0.15f
                        val spin = rng.range(-1f, 1f) * PI.toFloat() * j.angle
                        stamp(stroke.brush, center, w * 0.5f * scale, spin, color, rng, pen)
                    }
                }
            }

            else -> pen.line(pts, w, cg)
        }
    }

    /** 图案笔的一个图案。spin = 这一个随机转的角度。 */
    private fun stamp(brush: DoodleBrush, center: PointF, radius: Float, spin: Float, color: DoodleColor, rng: DoodleRandom, pen: Pen) {
        val c = pen.c
        val alpha = rng.range(0.85f, 1f)
        when (brush) {
            DoodleBrush.STARS -> pen.fill(starPath(center, radius, 0.42f, 5, spin), color.argb(alpha))
            DoodleBrush.HEARTS -> pen.fill(heartPath(center, radius, spin), color.argb(alpha))
            DoodleBrush.SPARKLES -> {
                val big = rng.unit() < 0.7f
                val r = if (big) radius else radius * 0.45f
                pen.shadow = r * 0.9f to color.argb()
                val fill = color.mixed(DoodleColor.white, 0.85f).argb(alpha)
                pen.fill(starPath(center, r, 0.2f, 4, spin * 0.4f), fill)
                // 旁边再带一颗小光点
                val d = PointF(center.x + rng.range(-0.9f, 0.9f) * radius, center.y + rng.range(-0.9f, 0.9f) * radius)
                pen.circle(d, max(radius * rng.range(0.06f, 0.14f), 0.4f), fill)
                pen.shadow = null
            }
            DoodleBrush.BUBBLES -> {
                val lw = max(radius * 0.13f, 0.5f)
                val ring = pen.paint(Paint.Style.STROKE, color.argb(alpha))
                ring.strokeWidth = lw
                ring.strokeCap = Paint.Cap.ROUND
                c.drawCircle(center.x, center.y, radius, ring)
                pen.circle(center, radius, color.argb(alpha * 0.18f))
                // 左上角一小段高光
                val hl = pen.paint(Paint.Style.STROKE, DoodleColor.white.argb(alpha * 0.9f))
                hl.strokeWidth = lw
                hl.strokeCap = Paint.Cap.ROUND
                val rr = radius * 0.62f
                c.drawArc(RectF(center.x - rr, center.y - rr, center.x + rr, center.y + rr), 189f, 63f, false, hl)
            }
            DoodleBrush.PETALS -> {
                // 樱花花瓣：尖头带一个小缺口，颜色深浅略有不同，根部更深一点
                val tint = color.mixed(DoodleColor.white, rng.range(0f, 0.35f))
                val path = petalPath(center, radius, spin + rng.range(-0.6f, 0.6f))
                val q = pen.paint(Paint.Style.FILL, color.argb(alpha))
                q.shader = RadialGradient(
                    center.x, center.y, max(radius * 1.1f, 0.01f),
                    intArrayOf(color.mixed(DoodleColor(0.85f, 0.3f, 0.45f), 0.35f).argb(alpha), tint.argb(alpha)),
                    floatArrayOf(0f, 0.6f), Shader.TileMode.CLAMP,
                )
                c.drawPath(path, q)
            }
            DoodleBrush.LEAVES -> {
                val leafColor = color.mixed(DoodleColor(0.55f, 0.2f, 0.05f), rng.range(0f, 0.4f))
                val rot = spin + rng.range(-0.8f, 0.8f)
                pen.fill(leafPath(center, radius, rot), leafColor.argb(alpha))
                // 叶脉
                val q = pen.paint(Paint.Style.STROKE, leafColor.mixed(DoodleColor.black, 0.35f).argb(alpha * 0.7f))
                q.strokeWidth = max(radius * 0.06f, 0.4f)
                c.drawLine(
                    center.x - cos(rot) * radius * 1.05f, center.y - sin(rot) * radius * 1.05f,
                    center.x + cos(rot) * radius * 0.9f, center.y + sin(rot) * radius * 0.9f, q,
                )
            }
            DoodleBrush.RAINDROPS -> {
                // 水滴：上尖下圆，半透明，左上一点高光
                val path = dropPath(center, radius * 0.8f, spin * 0.3f)
                pen.fill(path, color.argb(alpha * 0.45f))
                val q = pen.paint(Paint.Style.STROKE, color.mixed(DoodleColor.white, 0.5f).argb(alpha * 0.9f))
                q.strokeWidth = max(radius * 0.07f, 0.4f)
                c.drawPath(path, q)
                pen.circle(PointF(center.x - radius * 0.22f, center.y + radius * 0.05f), max(radius * 0.13f, 0.4f), DoodleColor.white.argb(alpha * 0.85f))
            }
            DoodleBrush.SNOWFLAKES -> {
                // 六个瓣，每瓣带两对小枝
                val q = pen.paint(Paint.Style.STROKE, color.argb(alpha))
                q.strokeWidth = max(radius * 0.1f, 0.5f)
                q.strokeCap = Paint.Cap.ROUND
                val path = Path()
                for (i in 0 until 6) {
                    val a = spin + i * PI.toFloat() / 3
                    path.moveTo(center.x, center.y)
                    path.lineTo(center.x + cos(a) * radius, center.y + sin(a) * radius)
                    for (k in floatArrayOf(0.45f, 0.72f)) {
                        val bx = center.x + cos(a) * radius * k
                        val by = center.y + sin(a) * radius * k
                        val twig = radius * (1 - k) * 0.7f
                        for (side in floatArrayOf(-1f, 1f)) {
                            val b = a + side * 0.75f
                            path.moveTo(bx, by)
                            path.lineTo(bx + cos(b) * twig, by + sin(b) * twig)
                        }
                    }
                }
                c.drawPath(path, q)
            }
            DoodleBrush.NOTES -> {
                val glyph = NOTE_GLYPHS[(rng.unit() * 4).toInt() % 4]
                c.save()
                c.translate(center.x, center.y)
                c.rotate(Math.toDegrees(spin * 0.5).toFloat())
                drawText(c, glyph, PointF(0f, 0f), radius * 2.2f, color.argb(alpha))
                c.restore()
            }
            else -> {}
        }
    }

    private val NOTE_GLYPHS = arrayOf("♪", "♫", "♩", "♬")

    /** 单位大小的路径先缩放、再旋转、最后挪到 center。 */
    private fun placed(path: Path, center: PointF, sx: Float, sy: Float, rotation: Float): Path {
        val m = Matrix()
        m.setScale(sx, sy)
        m.postRotate(Math.toDegrees(rotation.toDouble()).toFloat())
        m.postTranslate(center.x, center.y)
        path.transform(m)
        return path
    }

    /** 樱花花瓣：根部窄、尖头宽，尖头中间一个小缺口。 */
    private fun petalPath(center: PointF, radius: Float, rotation: Float): Path {
        val path = Path()
        path.moveTo(-1f, 0f)
        path.cubicTo(-0.4f, -0.75f, 0.4f, -0.8f, 0.85f, -0.55f)
        path.lineTo(0.7f, 0f)
        path.lineTo(0.85f, 0.55f)
        path.cubicTo(0.4f, 0.8f, -0.4f, 0.75f, -1f, 0f)
        path.close()
        return placed(path, center, radius, radius, rotation)
    }

    /** 两头尖的叶子。 */
    private fun leafPath(center: PointF, radius: Float, rotation: Float): Path {
        val path = Path()
        path.moveTo(-1.05f, 0f)
        path.cubicTo(-0.5f, -0.8f, 0.5f, -0.6f, 1f, 0f)
        path.cubicTo(0.5f, 0.6f, -0.5f, 0.8f, -1.05f, 0f)
        path.close()
        return placed(path, center, radius, radius * 0.85f, rotation)
    }

    /** 水滴：尖头朝上（y 朝下的坐标里是 -y）。 */
    private fun dropPath(center: PointF, radius: Float, rotation: Float): Path {
        val path = Path()
        path.moveTo(0f, -1.4f)
        path.cubicTo(0.5f, -0.6f, 1.2f, 0.9f, 0f, 0.9f)
        path.cubicTo(-1.2f, 0.9f, -0.5f, -0.6f, 0f, -1.4f)
        path.close()
        return placed(path, center, radius, radius, rotation)
    }

    private fun starPath(center: PointF, radius: Float, inner: Float, points: Int, rotation: Float): Path {
        val path = Path()
        for (i in 0 until points * 2) {
            val r = if (i % 2 == 0) radius else radius * inner
            val a = rotation - PI.toFloat() / 2 + i * PI.toFloat() / points
            val x = center.x + cos(a) * r
            val y = center.y + sin(a) * r
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        return path
    }

    private fun heartPath(center: PointF, radius: Float, rotation: Float): Path {
        // 以原点为中心、宽高大约是 2 的爱心（y 朝下）
        val path = Path()
        path.moveTo(0f, 0.9f)
        path.cubicTo(-0.55f, 0.55f, -1f, 0.2f, -1f, -0.2f)
        path.cubicTo(-1f, -0.85f, -0.25f, -0.95f, 0f, -0.45f)
        path.cubicTo(0.25f, -0.95f, 1f, -0.85f, 1f, -0.2f)
        path.cubicTo(1f, 0.2f, 0.55f, 0.55f, 0f, 0.9f)
        path.close()
        val m = Matrix()
        m.setScale(radius, radius)
        m.postRotate(Math.toDegrees(rotation.toDouble()).toFloat())
        m.postTranslate(center.x, center.y)
        path.transform(m)
        return path
    }

    // MARK: 标记的形状

    private fun shape(stroke: DoodleStroke, raw: List<PointF>, w: Float, pen: Pen) {
        val color = stroke.color
        val cg = color.argb()
        val a = raw[0]
        val b = raw[raw.size - 1]
        val box = RectF(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
        val c = pen.c

        when (stroke.brush) {
            DoodleBrush.ARROW -> {
                // 尾巴细、越往箭头越粗的实心箭头
                val total = dist(a, b)
                if (total <= 1) return
                val angle = atan2(b.y - a.y, b.x - a.x)
                val headLength = min(max(w * 4.2f, 3f), total * 0.6f)
                val headWidth = max(headLength * 0.95f, w * 2.2f)
                val tailHalf = w * 0.2f
                val neckHalf = w * 0.5f
                c.save()
                c.translate(a.x, a.y)
                c.rotate(Math.toDegrees(angle.toDouble()).toFloat())
                val neck = total - headLength * 0.86f
                val path = poly(listOf(
                    PointF(0f, -tailHalf), PointF(neck, -neckHalf),
                    PointF(total - headLength, -headWidth / 2), PointF(total, 0f),
                    PointF(total - headLength, headWidth / 2), PointF(neck, neckHalf),
                    PointF(0f, tailHalf),
                ))
                pen.fillStroke(path, cg, max(w * 0.12f, 0.5f))
                pen.circle(PointF(0f, 0f), tailHalf, cg)
                c.restore()
            }

            DoodleBrush.LINE -> {
                if (dist(a, b) <= 0.5f) return
                pen.line(listOf(a, b), w, cg)
            }

            DoodleBrush.RECT -> {
                if (box.width() <= 1 && box.height() <= 1) return
                val radius = min(w, min(box.width(), box.height()) / 2)
                val q = pen.paint(Paint.Style.STROKE, cg)
                q.strokeWidth = w
                c.drawRoundRect(box, radius, radius, q)
            }

            DoodleBrush.ELLIPSE -> {
                if (box.width() <= 1 && box.height() <= 1) return
                val q = pen.paint(Paint.Style.STROKE, cg)
                q.strokeWidth = w
                c.drawOval(box, q)
            }

            DoodleBrush.BAR -> {
                if (box.width() <= 1 || box.height() <= 1) return
                val radius = min(w * 0.8f, min(box.width(), box.height()) / 2)
                c.drawRoundRect(box, radius, radius, pen.paint(Paint.Style.FILL, cg))
            }

            DoodleBrush.NUMBER -> {
                val radius = w * 2.4f
                pen.shadow = radius * 0.3f to android.graphics.Color.argb(102, 0, 0, 0)
                pen.circle(b, radius, cg)
                pen.shadow = null
                val ink = if (color.isLight) DoodleColor(0.1f, 0.1f, 0.1f) else DoodleColor.white
                val ringPaint = pen.paint(Paint.Style.STROKE, ink.argb(0.95f))
                ringPaint.strokeWidth = radius * 0.13f
                c.drawCircle(b.x, b.y, radius * 0.84f, ringPaint)
                val text = "${stroke.number}"
                val fontSize = radius * when {
                    text.length <= 1 -> 1.2f
                    text.length == 2 -> 0.95f
                    else -> 0.72f
                }
                drawText(c, text, b, fontSize, ink.argb())
            }

            else -> {}
        }
    }

    private fun drawText(c: Canvas, text: String, center: PointF, fontSize: Float, color: Int) {
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = fontSize
            this.color = color
        }
        // 按字形的实际范围居中
        val r = Rect()
        p.getTextBounds(text, 0, text.length, r)
        c.drawText(text, center.x - r.exactCenterX(), center.y - r.exactCenterY(), p)
    }

    // MARK: 画笔缩略图

    /** 画笔列表上的示意图：用这支笔画一条波浪线。 */
    fun sample(brush: DoodleBrush, width: Int, height: Int): Bitmap? {
        val b = makeBitmap(width, height) ?: return null
        val points = (0..30).map { i ->
            val u = i / 30f
            PointF(0.13f + 0.74f * u, 0.52f - 0.3f * sin(u * PI.toFloat() * 3 + 0.4f) * (1 - 0.3f * u) + 0.06f * (u - 0.5f))
        }
        val stroke = DoodleStroke(
            brush, points, min(0.05f * brush.widthFactor, 0.34f), brush.sampleColor,
            max(brush.defaultOpacity, 0.85f), 20261122L,
        )
        draw(stroke, Canvas(b), width, height)
        return b
    }

}
