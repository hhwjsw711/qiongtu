package com.taoo.xiutu.tools.effect

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ml.PersonSegmenter
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.ImageTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.random.Random

/** 特效：光 / 模糊 / 复古 / 氛围 / AI 换天。 */
class EffectSession(model: EditorModel) : ToolSession(model, Tool.EFFECT) {
    enum class MaskStatus { IDLE, WORKING, READY, MISSING }

    var params by mutableStateOf(EffectParams())
        private set
    var category by mutableStateOf(EffectCategory.LIGHT)
    /** 每个效果套在当前照片小图上的样子（EffectKind.id → 图）。 */
    var thumbs by mutableStateOf<Map<String, Bitmap>>(emptyMap())
        private set
    var original by mutableStateOf<Bitmap?>(null)
        private set
    private var mask: Bitmap? = null
    var maskStatus by mutableStateOf(MaskStatus.IDLE)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    private var reopened: EffectParams? = null
    private var job: Job? = null
    private var closed = false

    override fun start() {
        val base = model.base ?: return
        maskStatus = MaskStatus.WORKING
        job = model.scope.launch {
            // 先出不需要蒙版的缩略图。
            val small = withContext(Dispatchers.Default) {
                runCatching { Img.thumb(base, 240, THUMB_ASPECT) }.getOrNull()
            }
            if (closed) return@launch
            if (small != null) {
                original = small
                val t = withContext(Dispatchers.Default) { makeThumbs(small, null, EffectKind.entries.filter { !it.needsMask }) }
                if (closed) return@launch
                thumbs = thumbs + t
            }
            // 再找主体。
            val found = withContext(Dispatchers.Default) {
                runCatching { PersonSegmenter.mask(base)?.let { Img.downscale(it, MASK_SIDE) } }.getOrNull()
            }
            if (closed) return@launch
            setMask(found)
            if (found == null || small == null) return@launch
            val t = withContext(Dispatchers.Default) {
                runCatching {
                    // 蒙版裁成和缩略图一样的一块
                    val m = Img.scaled(Img.centerCrop(Img.scaled(found, base.width, base.height), THUMB_ASPECT), small.width, small.height)
                    makeThumbs(small, m, EffectKind.entries.filter { it.usesMask })
                }.getOrElse { emptyMap() }
            }
            if (closed) return@launch
            thumbs = thumbs + t
        }
    }

    override fun close() {
        closed = true
        job?.cancel()
    }

    private fun makeThumbs(image: Bitmap, mask: Bitmap?, kinds: List<EffectKind>): Map<String, Bitmap> {
        val out = HashMap<String, Bitmap>()
        for (k in kinds) {
            if (closed) break
            val p = EffectParams(k.id, k.defaultStrength, 0, 7, mask = mask)
            runCatching { p.apply(image) }.onFailure { it.printStackTrace() }.getOrNull()?.let { out[k.id] = it }
        }
        return out
    }

    private fun setMask(found: Bitmap?) {
        // 重新打开时已经带着蒙版了：沿用原来的（预览和历史里那一步保持一样）。
        if (mask != null) return
        mask = found
        maskStatus = if (found == null) MaskStatus.MISSING else MaskStatus.READY
        val kind = params.kind ?: return
        if (!kind.usesMask) return
        if (found != null) {
            params = params.copy(mask = found)
            render()
        } else if (kind.needsMask) {
            // 先选了要蒙版的效果，结果没找到人。
            params = EffectParams()
            error = "没找到人物"
            render()
        }
    }

    override fun commitOps(): List<EditOp> = if (params.isIdentity) emptyList() else listOf(EffectOp(params))

    override fun reopen(op: EditOp) {
        val p = (op as? EffectOp)?.params ?: return
        params = p
        reopened = p
        p.kind?.let { category = it.category }
        if (p.mask != null) {
            mask = p.mask
            maskStatus = MaskStatus.READY
        }
        render()
    }

    override fun unchangedSinceReopen(): Boolean {
        val r = reopened ?: return false
        return r.sameSettings(params)
    }

    /** 选一个效果；null = 不要特效。 */
    fun select(kind: EffectKind?) {
        error = null
        if (kind == null) {
            params = EffectParams()
            render()
            return
        }
        if (kind.needsMask && maskStatus == MaskStatus.MISSING) {
            error = "没找到人物"
            return
        }
        var next = params
        if (next.id != kind.id) {
            next = next.copy(id = kind.id, strength = kind.defaultStrength, variant = 0)
            // 每次选一个随机排布的效果都重新随机一次，不会总是同一个样子。
            if (kind.shuffles) next = next.copy(seed = Random.nextLong(1, Long.MAX_VALUE))
        }
        params = next.copy(mask = if (kind.usesMask) mask else null)
        render()
    }

    fun setStrength(v: Float) {
        params = params.copy(strength = v.coerceIn(0f, 1f))
        render()
    }

    fun setVariant(i: Int) {
        params = params.copy(variant = i)
        render()
    }

    /** 随机的效果换一种排布。 */
    fun shuffle() {
        params = params.copy(seed = Random.nextLong(1, Long.MAX_VALUE))
        render()
    }

    /** 随机度 0.01…1。 */
    fun setChaos(v: Float) {
        params = params.copy(chaos = v.coerceIn(0.01f, 1f))
        render()
    }

    private fun render() {
        val p = params
        model.liveOnBase { base -> p.apply(base) }
    }

    // MARK: 面板

    @Composable
    override fun Panel() {
        val kind = params.kind
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 14.dp, bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            error?.let { Text(it, fontSize = 13.sp, color = Color(1f, 0.45f, 0.4f)) }
            SliderRow("强度", if (kind == null) null else params.strength, 0f..1f, Modifier.alpha(if (kind == null) 0.3f else 1f)) { setStrength(it) }
            if (kind != null && kind.shuffles) {
                SliderRow("随机度", params.chaos, 0.01f..1f) { setChaos(it) }
            }
            VariantRow(kind)
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (c in EffectCategory.entries) {
                    Chip(c.title, category == c, badge = if (c == EffectCategory.SKY) "AI" else null) { category = c }
                }
            }
            key(category) {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top,
                ) {
                    if (category == EffectCategory.SKY) {
                        for (sky in EffectSky.all) SkyTile(sky) { model.startAIPreset(sky.preset, AIPresetGroup.REMOVE) }
                    } else {
                        ImageTile("无", original, selected = kind == null, symbol = "circle.slash") { select(null) }
                        for (item in EffectKind.list(category)) {
                            Box {
                                ImageTile(item.title, thumbs[item.id], selected = kind == item, symbol = "sparkles") { select(item) }
                                if (item.needsMask && maskStatus == MaskStatus.WORKING && kind == item) {
                                    Box(Modifier.size(68.dp, 84.dp), contentAlignment = Alignment.Center) {
                                        CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /** 颜色 / 变体，随机排布的效果多一个"换一换"。没有时留出同样的高度，面板不跳。 */
    @Composable
    private fun VariantRow(kind: EffectKind?) {
        Row(
            Modifier.fillMaxWidth().height(32.dp).horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            if (kind != null) {
                kind.variants.forEachIndexed { i, v -> Chip(v.title, params.variant == i) { setVariant(i) } }
                if (kind.shuffles) {
                    Row(
                        Modifier.height(30.dp).press { shuffle() }.clip(CircleShape).background(Theme.chip).padding(horizontal = 12.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Icon(sym("dice"), null, tint = Color.White, modifier = Modifier.size(15.dp))
                        Text("随机", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    }
                }
            }
        }
    }

    /** 名字 + 滑条 + 数值（1…100）。 */
    @Composable
    private fun SliderRow(title: String, value: Float?, range: ClosedFloatingPointRange<Float>, modifier: Modifier = Modifier, set: (Float) -> Unit) {
        Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, fontSize = 13.sp, color = Color.White.copy(alpha = 0.6f), modifier = Modifier.width(44.dp))
            XSlider(value ?: 0f, set, range, Modifier.weight(1f), enabled = value != null)
            Text(
                value?.let { "${max((range.start * 100).toInt(), (it * 100).roundToInt())}" } ?: "–",
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                textAlign = TextAlign.End, modifier = Modifier.width(34.dp),
            )
        }
    }

    /** 换天的格子：渐变色块 + 图标，右上角 AI。 */
    @Composable
    private fun SkyTile(sky: EffectSky, onClick: () -> Unit) {
        Column(Modifier.width(68.dp).press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(
                Modifier.size(68.dp, 84.dp).clip(RoundedCornerShape(10.dp))
                    .background(Brush.verticalGradient(sky.colors.map { Color(0xFF000000.toInt() or it) })),
            ) {
                Icon(
                    sym(sky.symbol), null, tint = Color.White.copy(alpha = 0.92f),
                    modifier = Modifier.align(Alignment.TopCenter).offset(y = 84.dp * 0.36f - 13.dp).size(26.dp),
                )
                CornerBadge("AI", Modifier.align(Alignment.TopEnd).padding(4.dp))
            }
            Text(sky.title, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, color = Color.White)
        }
    }

    companion object {
        private const val THUMB_ASPECT = 68f / 84f
        private const val MASK_SIDE = 1024
    }
}

