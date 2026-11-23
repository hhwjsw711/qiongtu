package com.taoo.xiutu.tools.doodle

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PointF
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.hypot
import kotlin.math.max
import kotlin.random.Random

/** 涂鸦 / 标记：在图上画笔画、拖形状。tool = DOODLE 或 MARK。 */
class DoodleSession(model: EditorModel, tool: Tool) : ToolSession(model, tool) {
    /** 已经画完的笔画，按先后顺序。 */
    var strokes by mutableStateOf<List<DoodleStroke>>(emptyList())
        private set
    /** 撤销掉、还能重做的笔画。 */
    private var redo by mutableStateOf<List<DoodleStroke>>(emptyList())
    var category by mutableStateOf(DoodleCategory.PEN)
    var brush by mutableStateOf(if (tool == Tool.MARK) DoodleBrush.ARROW else DoodleBrush.PEN)
        private set
    var erasing by mutableStateOf(false)
    var color by mutableStateOf(if (tool == Tool.MARK) DoodleColor.red else DoodleColor.white)
    /** 笔在屏幕上的粗细（dp）。画面放大以后，同样的数值画出来更细，方便描细节。 */
    var size by mutableFloatStateOf(if (tool == Tool.MARK) 5f else 8f)
    /** 浓度：整笔的不透明度。 */
    var opacity by mutableFloatStateOf(1f)
    /** 自动圆润：手指抬起后把这一笔修顺（画圈变圆、近似直线拉直）。 */
    var smooth by mutableStateOf(prefs.getBoolean("smooth", true))
        private set
    /** 图案笔的随机分布。 */
    var jitter by mutableStateOf(DoodleJitter())
    /** 面板上显示分布滑条（代替颜色那一行）。 */
    var showJitter by mutableStateOf(false)
    /** 识别到的人脸（妆容笔用）；null = 还在识别。 */
    private var faces: List<FaceInfo>? = null
    /** 出错时的一句话（比如没找到人脸）。 */
    var note by mutableStateOf<String?>(null)
        private set

    /** 手指还没抬起来的这一笔。 */
    private var active: DoodleStroke? = null
    private var runtime: DoodleRuntime? = null
    private var reopenedFrom: List<DoodleStroke>? = null
    private val density = model.context.resources.displayMetrics.density
    private val prefs get() = model.context.getSharedPreferences("doodle", Context.MODE_PRIVATE)
    private var faceJob: Job? = null

    val canUndo get() = strokes.isNotEmpty()
    val canRedo get() = redo.isNotEmpty()

    override val drawing: Boolean get() = true

    override fun start() {
        val b = model.base ?: return
        runtime = DoodleRuntime.create(b.width, b.height)
        if (tool != Tool.DOODLE) return
        // 妆容笔要知道五官在哪：进来就在后台找脸
        faceJob = model.scope.launch {
            faces = withContext(Dispatchers.Default) { runCatching { FaceDetector.detect(b) }.getOrDefault(emptyList()) }
        }
    }

    override fun close() {
        faceJob?.cancel()
        faceJob = null
    }

    override fun reopen(op: EditOp) {
        val d = op as? DoodleOp ?: return
        strokes = d.strokes
        redo = emptyList()
        reopenedFrom = d.strokes
        render()
    }

    override fun unchangedSinceReopen(): Boolean = reopenedFrom == strokes

    override fun commitOps(): List<EditOp> {
        val op = DoodleOp(strokes)
        return if (op.isIdentity) emptyList() else listOf(op)
    }

    override fun strokeBegan(p: PointF, displayScale: Float) {
        if (displayScale <= 0 || runtime == null) return
        val b = if (erasing) DoodleBrush.ERASER else brush
        // 笔刷大小按屏幕上的 dp 算，存成相对图片长边的比例
        val width = (size * density * b.widthFactor / displayScale).coerceIn(0.0004f, 0.5f)
        val points = if (b.isShape && b != DoodleBrush.NUMBER) listOf(p, p) else listOf(p)
        var stroke = DoodleStroke(
            brush = b, points = points, width = width, color = color,
            opacity = if (b == DoodleBrush.ERASER) 1f else opacity,
            seed = Random.nextLong().let { if (it == 0L) 1L else it },
            number = if (b == DoodleBrush.NUMBER) strokes.count { it.brush == DoodleBrush.NUMBER } + 1 else 0,
        )
        if (b.category == DoodleCategory.MAKEUP) {
            // 妆容笔只画在对应的五官上；没找到脸就不画
            val found = faces
            if (found == null) {
                note = "还在识别人脸"
                return
            }
            val rt = runtime ?: return
            val region = DoodleFaceRegion.region(b, found, rt.width, rt.height)
            if (region.shapes.isEmpty()) {
                note = "没找到人脸"
                return
            }
            stroke = stroke.copy(region = region.shapes, feather = region.feather)
        } else if (b.category == DoodleCategory.PATTERN) {
            stroke = stroke.copy(jitter = jitter)
        }
        if (note != null) note = null
        active = stroke
        render()
    }

    override fun strokeMoved(p: PointF) {
        val s = active ?: return
        active = when {
            s.brush == DoodleBrush.NUMBER -> s.copy(points = listOf(p))
            s.brush.isShape -> s.copy(points = listOf(s.points[0], p))
            else -> {
                val last = s.points.last()
                if (hypot(last.x - p.x, last.y - p.y) < 0.0004f) return
                s.copy(points = s.points + p)
            }
        }
        render()
    }

    override fun strokeEnded() {
        val s = active ?: return
        val rt = runtime ?: return
        active = null
        var keep = true
        if (s.brush.isShape && s.brush != DoodleBrush.NUMBER && s.points.size >= 2) {
            // 只是点了一下、没拖开的形状不留
            val a = s.points[0]
            val b = s.points[1]
            val long = max(rt.width, rt.height).toFloat()
            val dragged = hypot((a.x - b.x) * rt.width, (a.y - b.y) * rt.height) / long
            keep = dragged > s.width * 0.8f + 0.004f
        }
        // 还什么都没画的时候，橡皮擦的这一笔也不用记
        if (s.brush == DoodleBrush.ERASER && strokes.none { it.brush != DoodleBrush.SPOT }) keep = false
        val done = if (keep && smooth && !s.brush.isShape && s.brush != DoodleBrush.ERASER) {
            s.copy(points = DoodleSmooth.process(s.points, rt.width, rt.height))
        } else s
        if (keep) {
            strokes = strokes + done
            redo = emptyList()
        }
        render()
    }

    /** 第二根手指落下、手势被取消：这一笔还没画完，直接作废。 */
    override fun strokeCancelled() = undoStroke()

    /** 撤销最后一笔。 */
    fun undoStroke() {
        if (active != null) {
            active = null
            render()
            return
        }
        if (!canUndo) return
        redo = redo + strokes.last()
        strokes = strokes.dropLast(1)
        render()
    }

    fun redoStroke() {
        if (active != null || !canRedo) return
        strokes = strokes + redo.last()
        redo = redo.dropLast(1)
        render()
    }

    /** 全部清掉。 */
    fun clearAll() {
        if (!canUndo) return
        active = null
        strokes = emptyList()
        redo = emptyList()
        render()
    }

    /** 换一支笔（或者标记里换一种形状）。浓度换成这支笔合适的默认值，妆容笔顺带换成对应的颜色。 */
    fun selectBrush(b: DoodleBrush) {
        brush = b
        erasing = false
        opacity = b.defaultOpacity
        b.defaultColor?.let { color = it }
        b.category?.let { category = it }
    }

    fun toggleSmooth() {
        smooth = !smooth
        prefs.edit().putBoolean("smooth", smooth).apply()
    }

    private fun render() {
        val rt = runtime ?: return
        val list = strokes
        val now = active
        model.liveOnBase { base -> rt.render(base, list, now) }
    }

    // MARK: 面板

    @Composable
    override fun Panel() {
        if (tool == Tool.MARK) MarkPanel() else DoodlePanel()
    }

    /** 涂鸦面板：选画笔、颜色、大小和浓度，直接在图上画。 */
    @Composable
    private fun DoodlePanel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            note?.let {
                Text(it, fontSize = 13.sp, color = Color(1f, 0.45f, 0.4f), modifier = Modifier.align(Alignment.CenterHorizontally))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                for (c in DoodleCategory.entries) Chip(c.title, selected = category == c) { category = c }
                Spacer(Modifier.weight(1f).widthIn(min = 4.dp))
                RoundButton("arrow.uturn.backward", enabled = canUndo) { undoStroke() }
                RoundButton("arrow.uturn.forward", enabled = canRedo) { redoStroke() }
                RoundButton("eraser", active = erasing) { erasing = !erasing }
                RoundButton("trash", enabled = canUndo) { clearAll() }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallSlider("大小", size, 2f..40f, Modifier.weight(1f)) { size = it }
                SmallSlider("浓度", opacity, 0.1f..1f, Modifier.weight(1f).alpha(if (erasing) 0.35f else 1f), enabled = !erasing) { opacity = it }
                Box(
                    Modifier.height(28.dp).clip(CircleShape).background(if (smooth) Theme.accent else Theme.chip)
                        .tap { toggleSmooth() }.padding(horizontal = 10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("圆润", fontSize = 12.5.sp, fontWeight = FontWeight.SemiBold, color = if (smooth) Color.Black else Color.White)
                }
            }
            if (category == DoodleCategory.PATTERN) {
                Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    RoundButton("slider.horizontal.3", active = showJitter) { showJitter = !showJitter }
                    if (showJitter) JitterSliders(Modifier.weight(1f)) else ColorRow(color) { color = it }
                }
            } else {
                ColorRow(color) { color = it }
            }
            key(category) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top,
                ) {
                    for (b in category.brushes) BrushTile(b, selected = !erasing && brush == b)
                }
            }
        }
    }

    /** 图案笔的分布：间距、散布、大小差、角度、数量。 */
    @Composable
    private fun JitterSliders(modifier: Modifier) {
        val j = jitter
        Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallSlider("间距", j.spacing, 0.3f..4f, Modifier.weight(1f)) { jitter = jitter.copy(spacing = it) }
                SmallSlider("散布", j.scatter, 0f..3f, Modifier.weight(1f)) { jitter = jitter.copy(scatter = it) }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SmallSlider("大小差", j.size, 0f..1f, Modifier.weight(1f)) { jitter = jitter.copy(size = it) }
                SmallSlider("角度", j.angle, 0f..1f, Modifier.weight(1f)) { jitter = jitter.copy(angle = it) }
                SmallSlider("数量", j.count, 1f..5f, Modifier.weight(1f)) { jitter = jitter.copy(count = it) }
            }
        }
    }

    /** 标记面板：箭头、方框、圆圈、序号这类标注，在图上拖出来。 */
    @Composable
    private fun MarkPanel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                for (s in DoodleBrush.shapes) IconTile(s.symbol, s.title, selected = brush == s) { selectBrush(s) }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val fixed = brush == DoodleBrush.BAR || brush == DoodleBrush.SPOT
                SmallSlider(
                    if (brush == DoodleBrush.NUMBER) "大小" else "粗细", size, 2f..20f,
                    Modifier.weight(1f).alpha(if (fixed) 0.35f else 1f), enabled = !fixed,
                ) { size = it }
                RoundButton("arrow.uturn.backward", enabled = canUndo) { undoStroke() }
                RoundButton("arrow.uturn.forward", enabled = canRedo) { redoStroke() }
                RoundButton("trash", enabled = canUndo) { clearAll() }
            }
            val spot = brush == DoodleBrush.SPOT
            Box(Modifier.alpha(if (spot) 0.35f else 1f)) {
                ColorRow(color, enabled = !spot) { color = it }
            }
        }
    }

    /** 画笔方块：上面是用这支笔画的示意线，下面是名字。 */
    @Composable
    private fun BrushTile(b: DoodleBrush, selected: Boolean) {
        Column(Modifier.press { selectBrush(b) }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Box(
                Modifier.size(72.dp, 44.dp).clip(RoundedCornerShape(10.dp)).background(tileBackground(b))
                    .border(2.5.dp, if (selected) Theme.accent else Color.Transparent, RoundedCornerShape(10.dp)),
                contentAlignment = Alignment.Center,
            ) {
                DoodleThumbs.image(b)?.let { Image(it, null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()) }
            }
            Text(
                b.title, fontSize = 11.5.sp, maxLines = 1,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                color = if (selected) Theme.accent else Color.White,
            )
        }
    }

    /** 妆容笔垫一块肤色，深色的笔垫灰底，其余垫深色，示意线才看得清。 */
    private fun tileBackground(b: DoodleBrush): Color {
        if (b.category == DoodleCategory.MAKEUP) return Color(0.93f, 0.78f, 0.69f)
        val c = b.sampleColor
        return if (0.299f * c.r + 0.587f * c.g + 0.114f * c.b < 0.3f) Color(0.5f, 0.5f, 0.5f) else Color(0.16f, 0.16f, 0.16f)
    }
}

/** 画笔列表上的示意图：每支笔画一条波浪线，只算一次。 */
object DoodleThumbs {
    private val cache = HashMap<DoodleBrush, ImageBitmap?>()

    fun image(brush: DoodleBrush): ImageBitmap? = cache.getOrPut(brush) {
        val b: Bitmap? = DoodleRenderer.sample(brush, 216, 132)
        b?.asImageBitmap()
    }
}

/** 一排颜色：最前面是自选颜色，后面是常用色。 */
@Composable
private fun ColorRow(selected: DoodleColor, enabled: Boolean = true, onPick: (DoodleColor) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        DecoColorWell(RGB(selected.r, selected.g, selected.b), 30.dp) { if (enabled) onPick(DoodleColor(it.r, it.g, it.b)) }
        Row(
            Modifier.weight(1f).horizontalScroll(rememberScrollState()).padding(1.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            for (c in DoodleColor.palette) {
                Box(
                    Modifier.size(30.dp).border(2.dp, if (selected == c) Theme.accent else Color.Transparent, CircleShape)
                        .padding(3.dp).clip(CircleShape).background(Color(c.r, c.g, c.b))
                        .border(1.dp, Color(0.4f, 0.4f, 0.4f), CircleShape)
                        .tap(enabled) { onPick(c) },
                )
            }
        }
    }
}

/** 面板上的小圆按钮（撤销、重做、橡皮、清空）。 */
@Composable
private fun RoundButton(symbol: String, active: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        Modifier.size(32.dp).alpha(if (enabled) 1f else 0.35f).clip(CircleShape)
            .background(if (active) Theme.accent else Theme.chip).tap(enabled, onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(sym(symbol), null, tint = if (active) Color.Black else Color.White, modifier = Modifier.size(16.dp))
    }
}

/** 名字 + 滑块。 */
@Composable
private fun SmallSlider(
    title: String, value: Float, range: ClosedFloatingPointRange<Float>, modifier: Modifier = Modifier,
    enabled: Boolean = true, onChange: (Float) -> Unit,
) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, fontSize = 13.sp, color = Theme.dim, maxLines = 1)
        XSlider(value, onChange, range, Modifier.weight(1f), enabled = enabled)
    }
}
