package com.taoo.xiutu.tools.collage

import android.graphics.Bitmap
import android.graphics.RectF
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyHorizontalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ui.BusyOverlay
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.SegmentBar
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// MARK: 画布

/**
 * 拼图时的画布：显示拼好的样子。
 * 模板：点空格子加图，点图选中，拖动挪图在格子里的位置，双指放大，长按后拖到别的格子换位置。
 * 拼接：可以滚动和双指缩放，末尾总有一个"添加图片"的空位。
 */
@Composable
fun CollageCanvas(s: CollageSession, modifier: Modifier) {
    Box(modifier.fillMaxSize()) {
        if (s.params.mode == CollageMode.TEMPLATE) TemplateCanvas(s) else StitchCanvas(s)
        if (s.loading) BusyOverlay()
    }
}

/** 实时预览是在后台算出来的，换模板的那一瞬间手上还是上一张图；比例对不上就先不显示，免得被拉变形。 */
@Composable
private fun PreviewPicture(image: Bitmap?, wanted: Float, modifier: Modifier) {
    val ok = image != null && image.height > 0 && abs(image.width.toFloat() / image.height - wanted) < wanted * 0.02f
    if (!ok || image == null) {
        Box(modifier.background(Color(0.12f, 0.12f, 0.12f)))
        return
    }
    val ib = remember(image) { image.asImageBitmap() }
    Canvas(modifier) {
        drawImage(ib, dstOffset = IntOffset.Zero, dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()), filterQuality = FilterQuality.High)
    }
}

private fun Float.toDp(density: Float): Dp = (this / density).dp

@Composable
private fun TemplateCanvas(s: CollageSession) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current.density
        val haptic = LocalHapticFeedback.current
        val params = s.params
        val (refW, refH) = s.reference
        val (cw, ch) = params.canvasSize(refW, refH, preview = true)
        val boxW = max(constraints.maxWidth - 24f * density, 1f)
        val boxH = max(constraints.maxHeight - 24f * density, 1f)
        val k = min(boxW / cw, boxH / ch)
        val fw = cw * k
        val fh = ch * k
        val frames = params.frames(fw, fh, refW, refH)
        val currentFrames by rememberUpdatedState(frames)
        val currentRef by rememberUpdatedState(refW to refH)

        Box(
            Modifier.align(Alignment.Center).size(fw.toDp(density), fh.toDp(density))
                .pointerInput(Unit) {
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val list = currentFrames
                        // 画中画的小格在上面，优先
                        val index = list.indices.reversed().firstOrNull { list[it].contains(down.position.x, down.position.y) }
                            ?: return@awaitEachGesture
                        val filled = index < s.params.pictures.size
                        val frame = list[index]
                        // 这个位置落在哪一格有图的格子上
                        fun cellAt(p: Offset): Int? {
                            val count = s.params.pictures.size
                            return list.indices.reversed().firstOrNull { it < count && list[it].contains(p.x, p.y) }
                        }
                        // 0 还没定，1 拖动，2 双指放大，3 长按换位置，4 不处理
                        var mode = 0
                        var panStart = Offset.Zero
                        var zoomStart = 1f
                        var spanStart = 0f
                        var lastPos = down.position
                        var lastTime = down.uptimeMillis
                        val longPressAt = down.uptimeMillis + 400
                        try {
                            while (true) {
                                val ev = if (mode == 0 && filled) {
                                    withTimeoutOrNull(max(1L, longPressAt - lastTime)) { awaitPointerEvent() }
                                } else awaitPointerEvent()
                                if (ev == null) {
                                    // 长按：开始换位置
                                    mode = 3
                                    s.swapFrom = index
                                    s.swapTo = null
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                    continue
                                }
                                lastTime = ev.changes.first().uptimeMillis
                                val pressed = ev.changes.filter { it.pressed }
                                if (pressed.isEmpty()) {
                                    when (mode) {
                                        0 -> s.tap(index)
                                        3 -> {
                                            val target = cellAt(lastPos)
                                            if (target != null && target != index) s.swap(index, target)
                                        }
                                    }
                                    break
                                }
                                if (pressed.size >= 2 && filled && mode != 3) {
                                    val span = (pressed[0].position - pressed[1].position).getDistance()
                                    if (mode != 2) {
                                        mode = 2
                                        zoomStart = s.params.pictures.getOrNull(index)?.zoom ?: 1f
                                        spanStart = max(span, 1f)
                                        if (s.selected != index) s.selected = index
                                    } else {
                                        s.zoom(index, zoomStart * span / spanStart)
                                    }
                                    ev.changes.forEach { it.consume() }
                                    continue
                                }
                                val c = pressed[0]
                                lastPos = c.position
                                when (mode) {
                                    0 -> if ((c.position - down.position).getDistance() > 6f * density) {
                                        if (filled) {
                                            mode = 1
                                            val p = s.params.pictures[index]
                                            panStart = Offset(p.ox, p.oy)
                                            if (s.selected != index) s.selected = index
                                        } else mode = 4
                                    }
                                    1 -> {
                                        val (rw, rh) = currentRef
                                        val (ex, ey) = s.params.fillExcess(index, frame.width(), frame.height(), rw, rh)
                                        var ox = panStart.x
                                        var oy = panStart.y
                                        if (ex > 0.5f) ox = panStart.x + (c.position.x - down.position.x) * 2 / ex
                                        if (ey > 0.5f) oy = panStart.y + (c.position.y - down.position.y) * 2 / ey
                                        s.pan(index, ox, oy)
                                    }
                                    3 -> {
                                        val target = cellAt(c.position)
                                        if (s.swapTo != target) s.swapTo = target
                                    }
                                }
                                c.consume()
                            }
                        } finally {
                            // 手势结束或被打断，都把"正在换位置"的标记清掉。
                            if (s.swapFrom == index) {
                                s.swapFrom = null
                                s.swapTo = null
                            }
                        }
                    }
                },
        ) {
            PreviewPicture(s.model.displayImage, cw / ch, Modifier.fillMaxSize())
            val count = params.pictures.size
            Canvas(Modifier.fillMaxSize()) {
                for ((index, f) in frames.withIndex()) {
                    val tl = Offset(f.left, f.top)
                    val sz = Size(f.width(), f.height())
                    if (index < count) {
                        if (s.swapFrom == index) drawRect(Color.Black.copy(alpha = 0.4f), tl, sz)
                        if (s.swapTo == index && s.swapFrom != null && s.swapFrom != index) drawRect(Theme.accent.copy(alpha = 0.35f), tl, sz)
                        if (s.selected == index) drawRect(Theme.accent, tl, sz, style = Stroke(2.5f * density))
                    } else {
                        drawRect(
                            Color(0.5f, 0.5f, 0.5f), tl, sz,
                            style = Stroke(density, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * density, 4 * density))),
                        )
                    }
                }
            }
            // 空格子："添加图片"
            for ((index, f) in frames.withIndex()) {
                if (index < count) continue
                val wdp = f.width() / density
                val hdp = f.height() / density
                Column(
                    Modifier.offset { IntOffset(f.left.roundToInt(), f.top.roundToInt()) }.size(wdp.dp, hdp.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                ) {
                    val tint = Color(0.42f, 0.42f, 0.42f)
                    Icon(sym("photo.badge.plus"), null, tint = tint, modifier = Modifier.size(min(24f, max(12f, wdp * 0.28f)).dp))
                    if (wdp > 76f && hdp > 64f) {
                        Spacer(Modifier.height(5.dp))
                        Text("添加图片", fontSize = 11.sp, color = tint)
                    }
                }
            }
        }
    }
}

@Composable
private fun StitchCanvas(s: CollageSession) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current.density
        val params = s.params
        val (refW, refH) = s.reference
        val (cw, ch) = params.canvasSize(refW, refH, preview = true)
        val vertical = params.vertical
        val aspect = max(cw, 1f) / max(ch, 1f)
        val boxW = constraints.maxWidth.toFloat()
        val boxH = constraints.maxHeight.toFloat()
        var stitchZoom by remember { mutableFloatStateOf(1f) }
        val dp = density
        // 末尾"添加图片"的空位沿拼接方向占多长。
        val slot = 104f * dp
        // 没放大时：图少就整条放进屏幕；图多了，宽度（竖拼）或高度（横拼）也不小于屏幕的一半多，剩下的靠滚动。
        var sw: Float
        var sh: Float
        if (vertical) {
            val widest = max(boxW - 32f * dp, 40f * dp)
            val fit = (boxH - 40f * dp - slot) * aspect
            sw = min(widest, max(fit, widest * 0.55f)) * stitchZoom
            sh = sw / aspect
        } else {
            val tallest = max(boxH - 32f * dp, 40f * dp)
            val fit = (boxW - 40f * dp - slot) / aspect
            sh = min(tallest, max(fit, tallest * 0.5f)) * stitchZoom
            sw = sh * aspect
        }
        val empty = params.pictures.isEmpty()
        if (empty) { if (vertical) sh = 0f else sw = 0f }
        val frames = params.frames(sw, sh, refW, refH)
        val currentFrames by rememberUpdatedState(frames)
        val cross = if (vertical) max(sw, 120f * dp) else max(sh, 120f * dp)
        val selected = s.selected

        Box(
            Modifier.fillMaxSize()
                .pointerInput(Unit) {
                    // 双指缩放整条长图（先于滚动拿到事件）
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        var start: Float? = null
                        var span0 = 1f
                        while (true) {
                            val ev = awaitPointerEvent(PointerEventPass.Initial)
                            val pressed = ev.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break
                            if (pressed.size >= 2) {
                                val span = (pressed[0].position - pressed[1].position).getDistance()
                                val st = start
                                if (st == null) {
                                    start = stitchZoom
                                    span0 = max(span, 1f)
                                } else {
                                    stitchZoom = (st * span / span0).coerceIn(0.5f, 3f)
                                }
                                ev.changes.forEach { it.consume() }
                            }
                        }
                    }
                }
                .verticalScroll(rememberScrollState())
                .horizontalScroll(rememberScrollState()),
        ) {
            Box(
                Modifier.defaultMinSize(minWidth = boxW.toDp(dp), minHeight = boxH.toDp(dp)).padding(16.dp),
                contentAlignment = Alignment.Center,
            ) {
                val content: @Composable () -> Unit = {
                    if (!empty) {
                        Box(
                            Modifier.size(sw.toDp(dp), sh.toDp(dp)).pointerInput(Unit) {
                                detectTapGestures { p ->
                                    val i = currentFrames.indexOfFirst { it.contains(p.x, p.y) }
                                    if (i >= 0) s.tap(i)
                                }
                            },
                        ) {
                            PreviewPicture(s.model.displayImage, cw / ch, Modifier.fillMaxSize())
                            Canvas(Modifier.fillMaxSize()) {
                                if (selected != null && selected in frames.indices) {
                                    val f = frames[selected]
                                    drawRect(Theme.accent, Offset(f.left, f.top), Size(f.width(), f.height()), style = Stroke(2.5f * dp))
                                }
                            }
                            StitchHandles(s, frames, vertical, if (vertical) sh else sw)
                        }
                    }
                    AddSlot(
                        if (vertical) cross.toDp(dp) else 104.dp,
                        if (vertical) 104.dp else cross.toDp(dp),
                    ) { s.requestAdd() }
                }
                if (vertical) {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally) { content() }
                } else {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { content() }
                }
            }
        }
    }
}

/** 拼接时一条可以推的边上的把手放在哪。 */
private class StitchHandle(val edge: StitchEdge, val x: Float, val y: Float)

/** 每条可以推的边放一个把手：第一张的开头、每两张之间、最后一张的结尾。 */
private fun stitchHandles(frames: List<RectF>, vertical: Boolean, inset: Float): List<StitchHandle> {
    val first = frames.firstOrNull() ?: return emptyList()
    val last = frames.last()
    val out = ArrayList<StitchHandle>()
    out += if (vertical) StitchHandle(StitchEdge.Start, first.centerX(), first.top + inset)
    else StitchHandle(StitchEdge.Start, first.left + inset, first.centerY())
    for (i in 0 until frames.size - 1) {
        val a = frames[i]
        out += if (vertical) StitchHandle(StitchEdge.Seam(i), a.centerX(), a.bottom)
        else StitchHandle(StitchEdge.Seam(i), a.right, a.centerY())
    }
    out += if (vertical) StitchHandle(StitchEdge.End, last.centerX(), last.bottom - inset)
    else StitchHandle(StitchEdge.End, last.right - inset, last.centerY())
    return out
}

/** 拼接时推拉裁剪的把手。along = 拼好的图在屏幕上沿拼接方向有多长（像素）。 */
@Composable
private fun StitchHandles(s: CollageSession, frames: List<RectF>, vertical: Boolean, along: Float) {
    val density = LocalDensity.current.density
    val currentAlong by rememberUpdatedState(along)
    val touchW = 60f * density
    val touchH = 44f * density
    for (handle in stitchHandles(frames, vertical, 14f * density)) {
        key(handle.edge) {
            val symbol = when (handle.edge) {
                StitchEdge.Start -> if (vertical) "arrow.up" else "arrow.left"
                is StitchEdge.Seam -> if (vertical) "arrow.up.arrow.down" else "arrow.left.arrow.right"
                StitchEdge.End -> if (vertical) "arrow.down" else "arrow.right"
            }
            Box(
                Modifier.offset { IntOffset((handle.x - touchW / 2).roundToInt(), (handle.y - touchH / 2).roundToInt()) }
                    .size(60.dp, 44.dp)
                    .pointerInput(handle.edge, vertical) {
                        awaitEachGesture {
                            val down = awaitFirstDown()
                            down.consume()
                            // 按下那一刻量一次屏幕上一个单位（图的宽 / 高）有多长，拖动中画布变长变短也不跟着变。
                            val start = s.params.pictures
                            val (refW, refH) = s.reference
                            val full = s.params.stitchFullLengths(refW, refH)
                            val kept = full.indices.sumOf { (full[it] * start[it].keep).toDouble() }.toFloat()
                            val gap = s.params.stitchGap * max(full.size - 1, 0)
                            val unit = currentAlong / max(kept + gap, 0.0001f)
                            // 把手跟着画布挪动，所以按每一帧的位移累加，而不是看当前位置。
                            var moved = 0f
                            while (true) {
                                val ev = awaitPointerEvent()
                                val c = ev.changes.firstOrNull { it.id == down.id } ?: break
                                if (!c.pressed) break
                                val d = c.position - c.previousPosition
                                val step = if (vertical) d.y else d.x
                                c.consume()
                                if (step == 0f) continue
                                moved += step
                                s.stitchPush(handle.edge, moved / max(unit, 0.0001f), start)
                            }
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    Modifier.size(if (vertical) 46.dp else 26.dp, if (vertical) 26.dp else 46.dp)
                        .shadow(3.dp, CircleShape).clip(CircleShape).background(Theme.accent),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(sym(symbol), null, tint = Color.Black, modifier = Modifier.size(15.dp))
                }
            }
        }
    }
}

@Composable
private fun AddSlot(width: Dp, height: Dp, onClick: () -> Unit) {
    val density = LocalDensity.current.density
    Box(Modifier.size(width, height).press(onClick = onClick), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val r = CornerRadius(10 * density, 10 * density)
            drawRoundRect(Color(0.1f, 0.1f, 0.1f), cornerRadius = r)
            drawRoundRect(
                Color(0.45f, 0.45f, 0.45f), cornerRadius = r,
                style = Stroke(density, pathEffect = PathEffect.dashPathEffect(floatArrayOf(6 * density, 5 * density))),
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            val tint = Color(0.6f, 0.6f, 0.6f)
            Icon(sym("photo.badge.plus"), null, tint = tint, modifier = Modifier.size(24.dp))
            Text("添加图片", fontSize = 12.sp, color = tint)
        }
    }
}

/** 模板的小图标：按模板的切法画出来。 */
@Composable
fun CollageLayoutIcon(layout: CollageLayout, ratio: Float, selected: Boolean, modifier: Modifier = Modifier) {
    val density = LocalDensity.current.density
    Box(
        modifier.size(52.dp).clip(RoundedCornerShape(11.dp)).background(Theme.chip)
            .border(1.5.dp, if (selected) Theme.accent else Color.Transparent, RoundedCornerShape(11.dp)),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val avail = Size(size.width - 14 * density, size.height - 14 * density)
            val bw: Float
            val bh: Float
            if (avail.width / avail.height > ratio) { bh = avail.height; bw = bh * ratio } else { bw = avail.width; bh = bw / ratio }
            val ox = (size.width - bw) / 2
            val oy = (size.height - bh) / 2
            val line = if (selected) Theme.accent else Color(0.75f, 0.75f, 0.75f)
            val inset = 1.1f * density
            val r = CornerRadius(2.2f * density, 2.2f * density)
            for ((index, cell) in layout.cells.withIndex()) {
                val tl = Offset(ox + cell.x * bw + inset, oy + cell.y * bh + inset)
                val sz = Size(cell.w * bw - inset * 2, cell.h * bh - inset * 2)
                // 画中画的小格先填上底色，把底下那格的线盖住。
                if (index >= layout.insetFrom) drawRoundRect(Color(0.16f, 0.16f, 0.16f), tl, sz, r)
                drawRoundRect(line, tl, sz, r, style = Stroke(1.5f * density))
            }
        }
    }
}

// MARK: 面板

private enum class CollagePage { LAYOUT, STYLE }

private enum class StyleKey(val title: String, val symbol: String, val limit: Float) {
    GAP("间距", "square.split.2x2", 0.06f),
    CORNER("圆角", "app", 0.12f),
    MARGIN("边距", "rectangle.inset.filled", 0.08f),
}

/** 拼图面板：模板 / 拼接。选中某一张图时换成这张图的操作。 */
@Composable
fun CollagePanel(s: CollageSession) {
    var page by remember { mutableStateOf(CollagePage.LAYOUT) }
    var styleKey by remember { mutableStateOf(StyleKey.GAP) }

    // 相册：一次选一张（换图）或多张（加图）
    val single = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) s.import(listOf(uri))
    }
    val limit = s.pickerLimit
    val multiContract = remember(limit) { ActivityResultContracts.PickMultipleVisualMedia(max(2, limit)) }
    val multi = rememberLauncherForActivityResult(multiContract) { uris ->
        if (uris.isNotEmpty()) s.import(uris.take(max(1, limit)))
    }
    LaunchedEffect(s.pickerShown) {
        if (!s.pickerShown) return@LaunchedEffect
        s.pickerShown = false
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        runCatching { if (limit <= 1) single.launch(request) else multi.launch(request) }
    }

    val params = s.params
    Column(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.width(196.dp)) {
                SegmentBar(
                    CollageMode.entries, params.mode, { it.title },
                    symbol = { if (it == CollageMode.TEMPLATE) "rectangle.split.2x2" else "rectangle.split.1x2" },
                ) { s.setMode(it) }
            }
            Spacer(Modifier.weight(1f))
            if (s.loading) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            Text("${params.pictures.size} 张图", fontSize = 12.sp, color = Theme.dim)
        }
        val index = s.selected
        when {
            index != null && index in params.pictures.indices -> PictureActions(s, index)
            params.mode == CollageMode.TEMPLATE -> {
                Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("版式", page == CollagePage.LAYOUT) { page = CollagePage.LAYOUT }
                    Chip("间距 · 圆角 · 底色", page == CollagePage.STYLE) { page = CollagePage.STYLE }
                }
                if (page == CollagePage.LAYOUT) LayoutPage(s) else StylePage(s, styleKey) { styleKey = it }
            }
            else -> StitchSection(s)
        }
        s.note?.let {
            Text(it, fontSize = 11.sp, color = Theme.accent, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
        }
    }
}

@Composable
private fun LayoutPage(s: CollageSession) {
    val params = s.params
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            RatioChip("全部", s.ratioFilter == null) { s.applyRatioFilter(null) }
            for (ratio in CollageRatio.entries) RatioChip(ratio.title, s.ratioFilter == ratio) { s.applyRatioFilter(ratio) }
        }
        val choices = s.choices
        LazyHorizontalGrid(
            rows = GridCells.Fixed(2),
            modifier = Modifier.fillMaxWidth().height(112.dp),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 1.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items(choices, key = { it.id }) { choice ->
                CollageLayoutIcon(
                    choice.layout, choice.ratio.value,
                    selected = choice.layout == params.layout && choice.ratio == params.ratio,
                    modifier = Modifier.press { s.select(choice.layout, choice.ratio) },
                )
            }
        }
    }
}

@Composable
private fun RatioChip(title: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        title, fontSize = 13.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        color = if (selected) Color.Black else Color.White,
        modifier = Modifier.clip(CircleShape).background(if (selected) Color.White else Theme.chip).tap(onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 6.dp),
    )
}

@Composable
private fun StylePage(s: CollageSession, key: StyleKey, onKey: (StyleKey) -> Unit) {
    val params = s.params
    fun value(k: StyleKey) = when (k) {
        StyleKey.GAP -> params.gap
        StyleKey.CORNER -> params.corner
        StyleKey.MARGIN -> params.margin
    }
    fun set(k: StyleKey, v0: Float) {
        val v = if (v0 < k.limit * 0.02f) 0f else v0
        when (k) {
            StyleKey.GAP -> s.setGap(v)
            StyleKey.CORNER -> s.setCorner(v)
            StyleKey.MARGIN -> s.setMargin(v)
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                "${(value(key) / key.limit * 100).roundToInt()}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                color = Color.White, modifier = Modifier.width(40.dp),
            )
            XSlider(value(key) / key.limit, { set(key, it * key.limit) }, modifier = Modifier.weight(1f))
        }
        Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for (item in StyleKey.entries) {
                IconTile(item.symbol, item.title, selected = item == key, modified = value(item) > 0f) { onKey(item) }
            }
        }
        ColorRow(s)
    }
}

/** 底色：间距、边距和拼接的间隔露出来的颜色。 */
@Composable
private fun ColorRow(s: CollageSession) {
    val current = s.params.background
    var picking by remember { mutableStateOf(false) }
    Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("底色", fontSize = 13.sp, color = Theme.dim)
        Row(
            Modifier.weight(1f).horizontalScroll(rememberScrollState()).padding(vertical = 2.dp, horizontal = 1.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            for (color in CollageColor.palette) {
                Box(
                    Modifier.size(30.dp).border(2.dp, if (color == current) Theme.accent else Color.Transparent, CircleShape)
                        .padding(3.dp).clip(CircleShape).background(Color(color.argb()))
                        .border(1.dp, Color(0.4f, 0.4f, 0.4f), CircleShape).tap { s.setBackground(color) },
                )
            }
        }
        // 自选底色
        Box(
            Modifier.size(28.dp).clip(CircleShape)
                .background(Brush.sweepGradient(listOf(Color.Red, Color.Yellow, Color.Green, Color.Cyan, Color.Blue, Color.Magenta, Color.Red)))
                .tap { picking = true },
            contentAlignment = Alignment.Center,
        ) { Box(Modifier.size(16.dp).clip(CircleShape).background(Color(current.argb()))) }
    }
    if (picking) ColorPickerDialog(current, onDismiss = { picking = false }) { s.setBackground(it) }
}

/** 自选颜色：色相、饱和度、亮度三条滑块，边调边生效。 */
@Composable
private fun ColorPickerDialog(initial: CollageColor, onDismiss: () -> Unit, onPick: (CollageColor) -> Unit) {
    val hsv = remember { FloatArray(3).also { android.graphics.Color.colorToHSV(initial.argb(), it) } }
    var h by remember { mutableFloatStateOf(hsv[0]) }
    var sat by remember { mutableFloatStateOf(hsv[1]) }
    var v by remember { mutableFloatStateOf(hsv[2]) }
    fun current(): CollageColor {
        val c = android.graphics.Color.HSVToColor(floatArrayOf(h, sat, v))
        return CollageColor(android.graphics.Color.red(c) / 255f, android.graphics.Color.green(c) / 255f, android.graphics.Color.blue(c) / 255f)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Theme.panel,
        confirmButton = { TextButton(onDismiss) { Text("完成", color = Theme.accent) } },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(10.dp)).background(Color(current().argb())))
                Box(
                    Modifier.fillMaxWidth().height(8.dp).clip(CircleShape)
                        .background(Brush.horizontalGradient((0..6).map { Color.hsv(it * 60f % 360f, 1f, 1f) })),
                )
                XSlider(h, { h = it; onPick(current()) }, 0f..360f)
                XSlider(sat, { sat = it; onPick(current()) }, 0f..1f)
                XSlider(v, { v = it; onPick(current()) }, 0f..1f)
            }
        },
    )
}

@Composable
private fun StitchSection(s: CollageSession) {
    val params = s.params
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            DirectionButton("竖拼", "rectangle.split.1x2", params.vertical, Modifier.weight(1f)) { s.setVertical(true) }
            DirectionButton("横拼", "rectangle.split.2x1", !params.vertical, Modifier.weight(1f)) { s.setVertical(false) }
        }
        Row(
            Modifier.padding(horizontal = 16.dp).fillMaxWidth().heightIn(min = 40.dp).clip(CircleShape).background(Theme.accent)
                .press { s.requestAdd() },
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(sym("photo.badge.plus"), null, tint = Color.Black, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text("添加图片", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.Black)
        }
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("间隔", fontSize = 13.sp, color = Theme.dim, modifier = Modifier.width(40.dp))
            XSlider(params.stitchGap / 0.08f, { x ->
                val v = x * 0.08f
                s.setStitchGap(if (v < 0.002f) 0f else v)
            }, modifier = Modifier.weight(1f))
        }
        if (params.stitchGap > 0f) ColorRow(s)
    }
}

@Composable
private fun DirectionButton(title: String, symbol: String, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val fg = if (selected) Theme.accent else Color.White
    Column(
        modifier.heightIn(min = 58.dp).clip(RoundedCornerShape(12.dp)).background(Theme.chip)
            .border(1.5.dp, if (selected) Theme.accent else Color.Transparent, RoundedCornerShape(12.dp))
            .press(onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Icon(sym(symbol), null, tint = fg, modifier = Modifier.size(22.dp))
        Spacer(Modifier.height(5.dp))
        Text(title, fontSize = 12.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, color = fg)
    }
}

/** 选中了某一张图。 */
@Composable
private fun PictureActions(s: CollageSession, index: Int) {
    val params = s.params
    val template = params.mode == CollageMode.TEMPLATE
    val last = index == params.pictures.size - 1
    val back = if (template) "arrow.left" else if (params.vertical) "arrow.up" else "arrow.left"
    val forward = if (template) "arrow.right" else if (params.vertical) "arrow.down" else "arrow.right"
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (template) "第 ${index + 1} 格" else "第 ${index + 1} 张", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            Spacer(Modifier.weight(1f))
            Text("完成", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Theme.accent, modifier = Modifier.tap { s.selected = null })
        }
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            IconTile("arrow.triangle.2.circlepath", "换图") { s.requestReplace(index) }
            IconTile("arrow.left.and.right.righttriangle.left.righttriangle.right", "翻转") { s.flip(index) }
            IconTile("rotate.right", "旋转") { s.rotate(index) }
            Box(Modifier.alpha(if (index == 0) 0.35f else 1f)) { IconTile(back, "前移") { s.move(index, -1) } }
            Box(Modifier.alpha(if (last) 0.35f else 1f)) { IconTile(forward, "后移") { s.move(index, 1) } }
            if (template) IconTile("arrow.counterclockwise", "位置还原") { s.resetFit(index) }
            IconTile("trash", "删除") { s.remove(index) }
        }
    }
}
