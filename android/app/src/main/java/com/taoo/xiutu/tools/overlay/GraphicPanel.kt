package com.taoo.xiutu.tools.overlay

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

private enum class GraphicTab(val title: String) {
    KIND("形状"), COLOR("颜色"), STROKE("描边"), SHADOW("阴影"), SIZE("大小"), CORNER("边角"),
}

/**
 * 形状面板：加方块、圆、多边形、星形、箭头、气泡……，改颜色、描边、阴影、大小和边角。
 * 形状和文字、贴纸一样浮在照片上面，AI 修图不会把它画进照片里。
 */
@Composable
fun GraphicPanel(s: OverlaySession) {
    var tab by remember { mutableStateOf(GraphicTab.KIND) }
    val selected = s.selected?.takeIf { it.isGraphic }
    LaunchedEffect(Unit) {
        // 进来时还没有形状就先放一条横条，直接就能拖、能改。
        if (s.items.none { it.isGraphic }) s.addGraphic(GraphicKind.RECT)
    }
    Column(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                Modifier.clip(CircleShape).background(Theme.accent)
                    .press { s.addGraphic(selected?.graphic?.kind ?: GraphicKind.RECT) }
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(sym("plus"), null, tint = Color.Black, modifier = Modifier.size(14.dp))
                Text("形状", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.Black)
            }
            Box(Modifier.weight(1f)) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(end = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    for (item in GraphicTab.entries) {
                        val on = tab == item
                        Column(Modifier.tap { tab = item }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(item.title, fontSize = 15.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, color = if (on) Color.White else Theme.dim, maxLines = 1)
                            Box(Modifier.size(16.dp, 3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
                        }
                    }
                }
            }
        }
        Box(Modifier.fillMaxWidth().height(128.dp)) {
            if (tab == GraphicTab.KIND) Kinds(s, selected)
            else if (selected != null) Content(s, tab, selected)
        }
    }
}

/** 改选中形状的样式参数。 */
private fun OverlaySession.changeGraphic(body: (GraphicStyle) -> GraphicStyle) =
    change { item -> item.graphic?.let { item.copy(graphic = body(it)) } ?: item }

/** 选中了形状就换它的种类，没选中就加一个新的。 */
@Composable
private fun Kinds(s: OverlaySession, selected: OverlayItem?) {
    EdgeRow(spacing = 10.dp, verticalAlignment = Alignment.Top) {
        for (kind in GraphicKind.entries) {
            val on = selected?.graphic?.kind == kind
            Column(
                Modifier.padding(vertical = 2.dp).press {
                    if (selected != null) {
                        s.change { item ->
                            var g = item.graphic ?: return@change item
                            var size = item.size
                            g = g.copy(kind = kind)
                            if (kind == GraphicKind.STAR) g = g.copy(sides = max(g.sides, 5))
                            if (kind != GraphicKind.RECT && g.aspect < 0.35f) {
                                // 从细长的横条换成别的形状：比例和大小都换成这个形状合适的。
                                g = g.copy(aspect = if (kind == GraphicKind.ARROW) 0.45f else 1f)
                                size = 0.35f / max(item.scale, 0.01f)
                            }
                            item.copy(graphic = g, size = size)
                        }
                    } else {
                        s.addGraphic(kind)
                    }
                },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                val fg = if (on) Theme.accent else Color.White
                Box(
                    Modifier.size(64.dp, 56.dp).clip(RoundedCornerShape(12.dp)).background(Theme.chip)
                        .border(2.dp, if (on) Theme.accent else Color.Transparent, RoundedCornerShape(12.dp)),
                    contentAlignment = Alignment.Center,
                ) { Icon(sym(kind.symbol), null, tint = fg, modifier = Modifier.size(26.dp)) }
                Text(kind.title, fontSize = 12.sp, color = fg, maxLines = 1)
            }
        }
    }
}

@Composable
private fun Content(s: OverlaySession, tab: GraphicTab, item: OverlayItem) {
    val g = item.graphic ?: GraphicStyle()
    val pad = Modifier.padding(horizontal = 16.dp)
    when (tab) {
        GraphicTab.KIND -> Unit
        GraphicTab.COLOR -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // "关掉" = 不填充，只留描边。
            OverlayColorRow(if (g.fill) item.color else null, allowsNone = true) { c ->
                s.change { i ->
                    val ig = i.graphic ?: return@change i
                    if (c != null) {
                        i.copy(color = c, graphic = ig.copy(fill = true))
                    } else {
                        val stroked = if (i.strokeOn) i else i.copy(strokeOn = true, strokeColor = i.color)
                        stroked.copy(graphic = ig.copy(fill = false))
                    }
                }
            }
            MiniSlider("不透明度", item.opacity, 0.05f..1f, pad, labelWidth = 56.dp) { v -> s.change { it.copy(opacity = v) } }
        }
        GraphicTab.STROKE -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OverlayColorRow(if (item.strokeOn) item.strokeColor else null, allowsNone = true) { c ->
                s.change { i ->
                    if (c != null) i.copy(strokeOn = true, strokeColor = c)
                    else i.copy(strokeOn = false, graphic = i.graphic?.copy(fill = true))
                }
            }
            MiniSlider("粗细", item.strokeWidth, 0.05f..1f, pad) { v -> s.change { it.copy(strokeOn = true, strokeWidth = v) } }
        }
        GraphicTab.SHADOW -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OverlayColorRow(if (item.shadowOn) item.shadowColor else null, allowsNone = true) { c ->
                s.change { if (c != null) it.copy(shadowOn = true, shadowColor = c) else it.copy(shadowOn = false) }
            }
            Row(pad, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MiniSlider("虚实", item.shadowBlur, 0f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowBlur = v) } }
                MiniSlider("距离", item.shadowDistance, 0f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowDistance = v) } }
            }
            Row(pad, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MiniSlider("角度", item.shadowAngle, 0f..360f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowAngle = v) } }
                MiniSlider("浓度", item.shadowOpacity, 0.1f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowOpacity = v) } }
            }
        }
        GraphicTab.SIZE -> Column(pad.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            MiniSlider("宽", item.size * item.scale, 0.03f..1.4f) { v -> s.change { it.copy(size = v / max(it.scale, 0.01f)) } }
            // 高按"高 / 宽"调，滑条用对数刻度：细长的字幕条和瘦高的竖条都好调。
            MiniSlider("高", log2(max(g.aspect, 0.05f)), -4.3f..2f) { v -> s.changeGraphic { it.copy(aspect = 2f.pow(v)) } }
        }
        GraphicTab.CORNER -> Column(pad.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (g.kind != GraphicKind.ELLIPSE && g.kind != GraphicKind.HEART) {
                MiniSlider("圆角", g.corner, 0f..1f) { v -> s.changeGraphic { it.copy(corner = v) } }
            }
            if (g.kind == GraphicKind.RECT) {
                MiniSlider("切角", g.cut, 0f..0.5f) { v -> s.changeGraphic { it.copy(cut = v) } }
                // 手机屏幕窄，四个角的开关单独放一行
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((bit, title) in listOf(1 to "左上", 2 to "右上", 8 to "左下", 4 to "右下")) {
                        Chip(title, g.cutCorners and bit != 0) {
                            s.changeGraphic { st ->
                                val corners = st.cutCorners xor bit
                                st.copy(cutCorners = corners, cut = if (st.cut == 0f && corners and bit != 0) 0.25f else st.cut)
                            }
                        }
                    }
                }
            }
            if (g.kind == GraphicKind.POLYGON || g.kind == GraphicKind.STAR) {
                val star = g.kind == GraphicKind.STAR
                MiniSlider(if (star) "角数" else "边数", g.sides.toFloat(), if (star) 4f..12f else 3f..12f) { v ->
                    s.changeGraphic { it.copy(sides = v.roundToInt()) }
                }
            }
        }
    }
}
