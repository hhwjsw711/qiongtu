package com.taoo.xiutu.tools.layers

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.rotateRad
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.EditorScreen
import com.taoo.xiutu.editor.LayerEditRequest
import com.taoo.xiutu.tools.overlay.OverlayItem
import com.taoo.xiutu.tools.overlay.OverlayOp
import com.taoo.xiutu.tools.overlay.OverlayRenderer
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

// MARK: 画布

/** 图层在画布上的几何：中心、半宽、半高（屏幕像素）。 */
private class LayerGeo(val center: Offset, val hw: Float, val hh: Float, val rotation: Float)

/** 局部坐标（随图层一起旋转）换到画布坐标。 */
private fun rotate(d: Offset, angle: Float): Offset {
    val c = cos(angle)
    val s = sin(angle)
    return Offset(d.x * c - d.y * s, d.x * s + d.y * c)
}

/** 角度差换到 -π...π，跨过 ±180° 时不会突然转一圈。 */
private fun normalized(a: Float): Float {
    var x = a
    while (x > Math.PI) x -= (2 * Math.PI).toFloat()
    while (x < -Math.PI) x += (2 * Math.PI).toFloat()
    return x
}

/**
 * 图层工具的画布：显示合成后的样子；点一下选中图层，拖动移动，双指或右下角手柄缩放旋转。
 */
@Composable
fun LayerCanvas(s: LayerSession, modifier: Modifier) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val density = LocalDensity.current.density
        val vw = constraints.maxWidth.toFloat()
        val vh = constraints.maxHeight.toFloat()
        val pad = 16f * density
        val image = s.model.displayImage
        val iw = (image?.width ?: 1).toFloat()
        val ih = (image?.height ?: 1).toFloat()
        val k = min(max(vw - pad * 2, 1f) / iw, max(vh - pad * 2, 1f) / ih)
        val fw = iw * k
        val fh = ih * k
        val left = (vw - fw) / 2
        val top = (vh - fh) / 2
        val minSide = 24f * density

        fun geo(layer: ImageLayer): LayerGeo {
            val w = max(layer.width * fw, minSide)
            val h = max(layer.width * fw * layer.aspect, minSide)
            return LayerGeo(Offset(left + layer.cx * fw, top + layer.cy * fh), w / 2, h / 2, layer.rotation)
        }

        val frame = floatArrayOf(left, top, fw, fh)
        val currentFrame by rememberUpdatedState(frame)
        val currentGeo by rememberUpdatedState(::geo)
        val bmp = remember(image) { image?.asImageBitmap() }
        val handleReach = 22f * density

        Box(
            Modifier.fillMaxSize().pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val f = currentFrame
                    val g = currentGeo
                    // 选中图层的两个手柄：左上删除，右下缩放旋转
                    val sel = s.selected?.takeIf { !it.hidden }
                    if (sel != null) {
                        val sg = g(sel)
                        val tl = sg.center + rotate(Offset(-sg.hw, -sg.hh), sg.rotation)
                        val br = sg.center + rotate(Offset(sg.hw, sg.hh), sg.rotation)
                        if ((down.position - tl).getDistance() < handleReach) {
                            down.consume()
                            var far = false
                            while (true) {
                                val ev = awaitPointerEvent()
                                val c = ev.changes.first()
                                if ((c.position - down.position).getDistance() > 40f) far = true
                                c.consume()
                                if (!c.pressed) break
                            }
                            if (!far) s.removeLayer(sel.id)
                            return@awaitEachGesture
                        }
                        if ((down.position - br).getDistance() < handleReach) {
                            down.consume()
                            val center = sg.center
                            val v0 = down.position - center
                            val len0 = max(v0.getDistance(), 1f)
                            val angle0 = atan2(v0.y, v0.x)
                            val width0 = sel.width
                            val rot0 = sel.rotation
                            while (true) {
                                val ev = awaitPointerEvent()
                                val c = ev.changes.firstOrNull { it.pressed } ?: break
                                val v = c.position - center
                                val len = max(v.getDistance(), 1f)
                                val angle = atan2(v.y, v.x)
                                s.updateLayer(sel.id) {
                                    it.copy(width = (width0 * len / len0).coerceIn(0.03f, 6f), rotation = rot0 + normalized(angle - angle0))
                                }
                                c.consume()
                            }
                            return@awaitEachGesture
                        }
                    }
                    // 点中的是哪一层（最上面的优先）
                    val hit = s.layers.lastOrNull { layer ->
                        if (layer.hidden) return@lastOrNull false
                        val lg = g(layer)
                        val local = rotate(down.position - lg.center, -lg.rotation)
                        abs(local.x) <= lg.hw && abs(local.y) <= lg.hh
                    }
                    val hitId = hit?.id
                    var moved = false
                    var multi = false
                    var dragStart: Offset? = null
                    var lastSpan = 0f
                    var lastAngle = 0f
                    var lastCentroid = Offset.Zero
                    while (true) {
                        val ev = awaitPointerEvent()
                        val pressed = ev.changes.filter { it.pressed }
                        if (pressed.isEmpty()) {
                            if (!moved && !multi) {
                                if (hitId != null) s.selectedId = hitId
                                else {
                                    val p = down.position
                                    if (p.x in f[0]..(f[0] + f[2]) && p.y in f[1]..(f[1] + f[3])) s.selectedId = null
                                }
                            }
                            break
                        }
                        if (hitId == null) continue
                        val cur = s.layers.firstOrNull { it.id == hitId } ?: break
                        if (pressed.size >= 2) {
                            val a = pressed[0].position
                            val b = pressed[1].position
                            val span = (b - a).getDistance()
                            val angle = atan2(b.y - a.y, b.x - a.x)
                            val centroid = (a + b) / 2f
                            if (!multi) {
                                multi = true
                                s.selectedId = hitId
                            } else {
                                val zoom = if (lastSpan > 1f) span / lastSpan else 1f
                                val turn = normalized(angle - lastAngle)
                                val d = centroid - lastCentroid
                                s.updateLayer(hitId) {
                                    it.copy(
                                        width = (it.width * zoom).coerceIn(0.03f, 6f),
                                        rotation = it.rotation + turn,
                                        cx = (it.cx + d.x / f[2]).coerceIn(-0.3f, 1.3f),
                                        cy = (it.cy + d.y / f[3]).coerceIn(-0.3f, 1.3f),
                                    )
                                }
                            }
                            lastSpan = span
                            lastAngle = angle
                            lastCentroid = centroid
                            moved = true
                            ev.changes.forEach { it.consume() }
                        } else if (!multi) {
                            val c = pressed[0]
                            if (!moved && (c.position - down.position).getDistance() > 2f * density) {
                                moved = true
                                dragStart = Offset(cur.cx, cur.cy)
                                s.selectedId = hitId
                            }
                            val start = dragStart
                            if (moved && start != null && f[2] > 0f && f[3] > 0f) {
                                val x = start.x + (c.position.x - down.position.x) / f[2]
                                val y = start.y + (c.position.y - down.position.y) / f[3]
                                s.updateLayer(hitId) { it.copy(cx = x.coerceIn(-0.3f, 1.3f), cy = y.coerceIn(-0.3f, 1.3f)) }
                            }
                            c.consume()
                        }
                    }
                }
            },
        ) {
            Canvas(Modifier.fillMaxSize()) {
                if (bmp != null) {
                    drawImage(
                        bmp, dstOffset = IntOffset(left.roundToInt(), top.roundToInt()),
                        dstSize = IntSize(fw.roundToInt(), fh.roundToInt()), filterQuality = FilterQuality.High,
                    )
                }
                // 选中图层的虚线框
                val sel = s.selected?.takeIf { !it.hidden }
                if (sel != null) {
                    val g = geo(sel)
                    rotateRad(g.rotation, g.center) {
                        drawRect(
                            Color.White, topLeft = Offset(g.center.x - g.hw, g.center.y - g.hh), size = Size(g.hw * 2, g.hh * 2),
                            style = Stroke(width = density, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * density, 4 * density))),
                        )
                    }
                }
            }
            val sel = s.selected?.takeIf { !it.hidden }
            if (sel != null) {
                val g = geo(sel)
                val tl = g.center + rotate(Offset(-g.hw, -g.hh), g.rotation)
                val br = g.center + rotate(Offset(g.hw, g.hh), g.rotation)
                ChromeHandle("xmark", tl, sel.rotation)
                ChromeHandle("arrow.up.left.and.arrow.down.right", br, sel.rotation)
            }
        }
    }
}

/** 手柄的样子；点按由画布统一处理。 */
@Composable
private fun ChromeHandle(symbol: String, center: Offset, rotation: Float) {
    val density = LocalDensity.current.density
    val half = 13f * density
    Box(
        Modifier.offset { IntOffset((center.x - half).roundToInt(), (center.y - half).roundToInt()) }
            .size(26.dp)
            .graphicsLayer { rotationZ = Math.toDegrees(rotation.toDouble()).toFloat() }
            .clip(androidx.compose.foundation.shape.CircleShape).background(Color.White),
        contentAlignment = Alignment.Center,
    ) { Icon(sym(symbol), null, tint = Color.Black, modifier = Modifier.size(13.dp)) }
}

// MARK: 面板

/** 图层面板：上面一排是所有图层（最上面的排最前），下面是选中那一层能做的事。 */
@Composable
fun LayerPanel(s: LayerSession) {
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) s.addLayer(uri)
    }
    Column(
        Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 4.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (s.fusing) FusingRow(s.fuseStarted)
        Strip(s) { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
        val layer = s.selected
        if (layer != null) {
            SliderRow(s, layer)
            Actions(s, layer)
        } else {
            Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                IconTile("slider.horizontal.3", "编辑照片", enabled = !s.working) { s.editRequest = s.backgroundEditRequest() }
            }
        }
        s.note?.let {
            Text(it, fontSize = 12.sp, color = Color(1f, 0.45f, 0.4f), modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
        }
    }
    s.editRequest?.let { req -> LayerEditDialog(req) { if (s.editRequest === req) s.editRequest = null } }
}

@Composable
private fun FusingRow(started: Long) {
    val seconds by produceState(0, started) {
        while (true) {
            value = max(0, ((System.currentTimeMillis() - started) / 1000).toInt())
            delay(1000)
        }
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        Text("正在融合… $seconds 秒", fontSize = 14.sp, color = Color.White)
    }
}

@Composable
private fun Strip(s: LayerSession, onAdd: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 6.dp, bottom = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top,
    ) {
        // 添加
        Column(
            Modifier.press(!s.working, onAdd),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.size(54.dp).clip(RoundedCornerShape(12.dp)).background(Theme.accent), contentAlignment = Alignment.Center) {
                if (s.working) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
                else Icon(sym("plus"), null, tint = Color.Black, modifier = Modifier.size(24.dp))
            }
            Text("添加", fontSize = 11.5.sp, color = Color.White)
        }
        if (s.layers.isNotEmpty()) {
            Column(
                Modifier.press(!s.working) { s.fuseLayers() },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box {
                    Box(Modifier.size(54.dp).clip(RoundedCornerShape(12.dp)).background(Theme.chip), contentAlignment = Alignment.Center) {
                        Icon(sym("wand.and.sparkles"), null, tint = Color.White, modifier = Modifier.size(24.dp))
                    }
                    CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = 5.dp, y = (-4).dp))
                }
                Text("AI 融合", fontSize = 11.5.sp, color = Color.White)
            }
        }
        // 文字、贴纸、形状也是浮在照片上的一层：点一下转到对应的工具接着改。
        for (item in decorations(s).asReversed()) {
            key(item.id) { DecorationThumb(s, item) }
        }
        for (layer in s.layers.reversed()) {
            key(layer.id) {
                Thumb(layer.name, layer.preview, s.selectedId == layer.id, layer.hidden) { s.selectedId = layer.id }
            }
        }
        Thumb("照片", s.background, s.selectedId == null, false) { s.selectedId = null }
    }
}

/** 历史里所有的文字、贴纸、形状（先加的在前）。 */
private fun decorations(s: LayerSession): List<OverlayItem> =
    s.model.ops.flatMap { (it as? OverlayOp)?.items ?: emptyList() }

private fun decorationTitle(item: OverlayItem): String = when {
    item.graphic != null -> item.graphic.kind.title
    item.isImage -> "贴纸"
    item.isSticker -> item.text
    else -> item.text.replace("\n", " ").take(5)
}

@Composable
private fun DecorationThumb(s: LayerSession, item: OverlayItem) {
    val density = LocalDensity.current.density
    val image = remember(item) {
        // 图片和形状按宽度画，文字按字号画
        val size = if (item.isImage || item.isGraphic) 50f else 30f
        runCatching { OverlayRenderer.thumbnail(item, size * density) }.getOrNull()
    }
    Thumb(decorationTitle(item), image, false, false) {
        if (!s.working) s.model.commitTool { s.model.open(item.tool, selecting = item.id) }
    }
}

@Composable
private fun Thumb(title: String, image: Bitmap?, selected: Boolean, hidden: Boolean, onClick: () -> Unit) {
    Column(Modifier.press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(
            Modifier.size(54.dp).clip(RoundedCornerShape(12.dp)).background(Color(0.2f, 0.2f, 0.2f))
                .border(2.5.dp, if (selected) Theme.accent else Color.Transparent, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            if (image != null) {
                val ib = remember(image) { image.asImageBitmap() }
                Image(ib, null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().padding(2.dp))
            }
            if (hidden) {
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)))
                Icon(sym("eye.slash"), null, tint = Color.White, modifier = Modifier.size(18.dp))
            }
        }
        Text(
            title, fontSize = 11.5.sp, maxLines = 1, softWrap = false,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Theme.accent else Color.White, modifier = Modifier.width(58.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        )
    }
}

/** 不透明度（抠过图时可以切换成边缘羽化）。 */
@Composable
private fun SliderRow(s: LayerSession, layer: ImageLayer) {
    // 滑块当前调的是不是羽化（否则是不透明度）
    var adjustingFeather by remember { mutableStateOf(false) }
    var featherDraft by remember { mutableStateOf<Float?>(null) }
    val feather = adjustingFeather && layer.cutout
    val value = if (feather) featherDraft ?: layer.feather else layer.opacity
    Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            Modifier.width(78.dp).tap { if (layer.cutout) adjustingFeather = !adjustingFeather },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            val fg = if (layer.cutout) Color.White else Theme.dim
            Text(if (feather) "边缘羽化" else "不透明度", fontSize = 13.sp, color = fg, maxLines = 1)
            if (layer.cutout) Icon(sym("chevron.up.chevron.down"), null, tint = fg, modifier = Modifier.size(11.dp))
        }
        XSlider(
            value,
            onChange = { v ->
                if (feather) featherDraft = v else s.updateLayer(layer.id) { it.copy(opacity = v) }
            },
            modifier = Modifier.weight(1f),
            onFinished = {
                // 羽化要重新抠一遍边，松手才算。
                val draft = featherDraft
                if (feather && draft != null) {
                    featherDraft = null
                    s.setLayerFeather(layer.id, draft)
                }
            },
        )
        Text(
            "${(value * 100).roundToInt()}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
            modifier = Modifier.width(34.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
    }
}

@Composable
private fun Actions(s: LayerSession, layer: ImageLayer) {
    val id = layer.id
    val busy = s.working
    val index = s.layers.indexOfFirst { it.id == id }.coerceAtLeast(0)
    var blendMenu by remember { mutableStateOf(false) }
    fun act(f: () -> Unit): () -> Unit = { if (!s.working) f() }
    Row(
        Modifier.fillMaxWidth().alpha(if (busy) 0.5f else 1f).horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        IconTile("slider.horizontal.3", "编辑", modified = layer.ops.isNotEmpty(), onClick = act { s.editRequest = s.layerEditRequest(id) })
        IconTile(if (busy) "hourglass" else "person.crop.rectangle", "去背景", selected = layer.cutout, onClick = act { s.setLayerCutout(id, !layer.cutout) })
        IconTile("wand.and.stars", "AI 去背景", badge = "AI", onClick = act { s.aiCutoutLayer(id) })
        Box {
            IconTile(
                "circle.lefthalf.filled", if (layer.blend == LayerBlend.NORMAL) "混合" else layer.blend.title,
                selected = layer.blend != LayerBlend.NORMAL, onClick = act { blendMenu = true },
            )
            DropdownMenu(blendMenu, onDismissRequest = { blendMenu = false }, containerColor = Theme.panel) {
                for (blend in LayerBlend.entries) {
                    DropdownMenuItem(
                        text = { Text(blend.title, color = Color.White) },
                        trailingIcon = if (layer.blend == blend) ({ Icon(sym("checkmark"), null, tint = Color.White) }) else null,
                        onClick = {
                            blendMenu = false
                            s.updateLayer(id) { it.copy(blend = blend) }
                        },
                    )
                }
            }
        }
        IconTile("arrow.left.and.right.righttriangle.left.righttriangle.right", "翻转", selected = layer.flipped,
            onClick = act { s.updateLayer(id) { it.copy(flipped = !it.flipped) } })
        IconTile("arrow.up.left.and.arrow.down.right", "铺满", onClick = act { s.fitLayer(id) })
        IconTile("square.on.square", "复制", onClick = act { s.duplicateLayer(id) })
        Box(Modifier.alpha(if (index < s.layers.size - 1) 1f else 0.35f)) {
            IconTile("arrow.up.square", "上移", onClick = act { s.moveLayer(id, 1) })
        }
        Box(Modifier.alpha(if (index > 0) 1f else 0.35f)) {
            IconTile("arrow.down.square", "下移", onClick = act { s.moveLayer(id, -1) })
        }
        IconTile(if (layer.hidden) "eye" else "eye.slash", if (layer.hidden) "显示" else "隐藏",
            onClick = act { s.updateLayer(id) { it.copy(hidden = !it.hidden) } })
        IconTile("trash", "删除", onClick = act { s.removeLayer(id) })
    }
}

/** 单独编辑一个图层（或下面的照片）：全屏打开第二个编辑器，有自己的 EditorModel，关掉时释放。 */
@Composable
private fun LayerEditDialog(req: LayerEditRequest, onClose: () -> Unit) {
    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(
            usePlatformDefaultWidth = false, decorFitsSystemWindows = false,
            dismissOnBackPress = false, dismissOnClickOutside = false,
        ),
    ) {
        val context = LocalContext.current
        val inner = remember(req.id) { EditorModel(context).also { it.load(req.source, req.ops) } }
        Box(Modifier.fillMaxSize().background(Theme.bg)) {
            EditorScreen(inner, null, layerEdit = req, onClose = onClose)
        }
    }
}
