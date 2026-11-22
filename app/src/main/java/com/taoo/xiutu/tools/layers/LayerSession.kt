package com.taoo.xiutu.tools.layers

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.taoo.xiutu.ai.AIClient
import com.taoo.xiutu.ai.AIEdit
import com.taoo.xiutu.ai.AIError
import com.taoo.xiutu.ai.AIRunner
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.ai.ToneTransfer
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.LayerEditRequest
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.ml.Cutout
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.PersonSegmenter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 图层工具打开期间的全部状态。
 *
 * 图层在编辑历史里是一步（LayerStack）。它前面的步骤属于"图层下面的照片"，
 * 后面的步骤（之后做的滤镜、调色……）作用在合并后的整张图上。
 * 再次打开图层工具时，是把历史里的这一步拿出来原地修改，前后的步骤都保留。
 */
class LayerSession(model: EditorModel) : ToolSession(model, Tool.LAYERS) {
    /** 从下到上。 */
    var layers by mutableStateOf<List<ImageLayer>>(emptyList())
        private set
    /** null = 选中的是下面的照片。 */
    var selectedId by mutableStateOf<String?>(null)
    /** 正在导入、抠图或重新生成图层内容。 */
    var working by mutableStateOf(false)
        private set
    var note by mutableStateOf<String?>(null)
    /** 正在 AI 融合。 */
    var fusing by mutableStateOf(false)
        private set
    var fuseStarted = 0L
        private set
    /** 图层下面的照片（预览大小）。 */
    var background by mutableStateOf<Bitmap?>(null)
        private set
    /** 正在单独编辑的图层内容（或下面的照片）。 */
    var editRequest by mutableStateOf<LayerEditRequest?>(null)

    /** 图层下面那张照片的修改步骤。 */
    private var prefix: List<EditOp> = emptyList()
    /** 图层之后的步骤。 */
    private var suffix: List<EditOp> = emptyList()
    private var changed = false
    /** 给新图层起名用。 */
    private var counter = 0
    private var closed = false
    private var fuseJob: Job? = null

    val selected: ImageLayer? get() = selectedId?.let { id -> layers.firstOrNull { it.id == id } }

    override val busy: Boolean get() = working
    override val customCanvas: Boolean get() = true

    // MARK: 进出

    override fun start() {
        val ops = model.ops
        val index = ops.indexOfLast { it is LayerStack }
        if (index >= 0) {
            val stack = ops[index] as LayerStack
            layers = stack.layers
            prefix = ops.subList(0, index).toList()
            suffix = ops.subList(index + 1, ops.size).toList()
            selectedId = stack.layers.lastOrNull()?.id
        } else {
            prefix = ops
            background = model.base
        }
        counter = layers.size
        if (background == null) rebuildBackground()
    }

    override fun commitOps(): List<EditOp> = emptyList()

    /** 点 ✓：把图层这一步写回历史里原来的位置。没改过就什么都不动。 */
    override fun replacementOps(): List<EditOp>? {
        if (!changed) return null
        val list = ArrayList(prefix)
        if (layers.isNotEmpty()) list += LayerStack(layers)
        list += suffix
        return list
    }

    override fun close() {
        closed = true
        fuseJob?.cancel()
        editRequest = null
    }

    @Composable
    override fun Canvas(modifier: Modifier) = LayerCanvas(this, modifier)

    @Composable
    override fun Panel() = LayerPanel(this)

    // MARK: 预览

    /** 重新算一遍"图层下面的照片"的预览。 */
    private fun rebuildBackground() {
        val proxy = model.proxy ?: return
        val list = prefix
        working = true
        model.scope.launch {
            val out = withContext(Dispatchers.Default) {
                runCatching { Img.downscale(EditOp.applyAll(list, proxy), EditorModel.PREVIEW_SIDE) }
                    .onFailure { it.printStackTrace() }.getOrNull()
            }
            if (closed) return@launch
            working = false
            if (out != null) background = out
            render()
        }
    }

    /** 实时预览：下面的照片 + 各个图层的小图。 */
    fun render() {
        if (closed) return
        val bg = background ?: return
        val list = layers
        model.live { LayerRender.composite(bg, list, usePreview = true) }
    }

    // MARK: 增删改

    /** 从相册选的一张图，加成新图层。 */
    fun addLayer(uri: Uri) {
        if (closed || working) return
        working = true
        note = null
        val number = counter + 1
        val bg = background
        val canvasW = bg?.width?.toFloat() ?: 1f
        val canvasH = bg?.height?.toFloat() ?: 1f
        val context = model.context
        model.scope.launch {
            val made = withContext(Dispatchers.Default) {
                runCatching { Img.decode(context, uri, ImageLayer.MAX_SIDE)?.let { ImageLayer.make("图层 $number", it) } }.getOrNull()
            }
            if (closed) return@launch
            working = false
            if (made == null) {
                note = "这张图片读不出来。"
                return@launch
            }
            val layer = made.copy(width = fittingWidth(made.aspect, canvasW, canvasH, 0.7f))
            counter = number
            layers = layers + layer
            selectedId = layer.id
            changed = true
            render()
        }
    }

    fun updateLayer(id: String, change: (ImageLayer) -> ImageLayer) {
        val i = layers.indexOfFirst { it.id == id }
        if (i < 0) return
        layers = layers.toMutableList().also { it[i] = change(it[i]) }
        changed = true
        render()
    }

    fun removeLayer(id: String) {
        val i = layers.indexOfFirst { it.id == id }
        if (i < 0) return
        val list = layers.toMutableList().also { it.removeAt(i) }
        layers = list
        if (selectedId == id) {
            selectedId = if (i - 1 in list.indices) list[i - 1].id else list.firstOrNull()?.id
        }
        changed = true
        render()
    }

    fun duplicateLayer(id: String) {
        val i = layers.indexOfFirst { it.id == id }
        if (i < 0) return
        counter += 1
        val src = layers[i]
        val copy = src.copy(
            id = UUID.randomUUID().toString(), name = "图层 $counter",
            cx = min(src.cx + 0.05f, 1f), cy = min(src.cy + 0.05f, 1f),
        )
        layers = layers.toMutableList().also { it.add(i + 1, copy) }
        selectedId = copy.id
        changed = true
        render()
    }

    /** 往上（delta = 1）或往下（delta = -1）挪一层。 */
    fun moveLayer(id: String, delta: Int) {
        val i = layers.indexOfFirst { it.id == id }
        if (i < 0) return
        val j = i + delta
        if (j !in layers.indices) return
        layers = layers.toMutableList().also { val t = it[i]; it[i] = it[j]; it[j] = t }
        changed = true
        render()
    }

    /** 摆回正中间，大小正好铺进画面。 */
    fun fitLayer(id: String) {
        val bg = background
        val w = bg?.width?.toFloat() ?: 1f
        val h = bg?.height?.toFloat() ?: 1f
        updateLayer(id) { it.copy(cx = 0.5f, cy = 0.5f, rotation = 0f, width = fittingWidth(it.aspect, w, h, 1f)) }
    }

    // MARK: 抠图 / 单独编辑

    /** 开关"去背景"。第一次打开时在本机识别一次主体。 */
    fun setLayerCutout(id: String, on: Boolean) {
        rebuildLayer(id, editedChanged = false, failure = "本机没有识别到主体，可以用 AI 去背景。") { it.copy(cutout = on) }
    }

    /** AI 去背景：让 AI 把背景换成绿幕，本机再按绿幕算出蒙版，贴上去的仍然是原图的像素。 */
    fun aiCutoutLayer(id: String) {
        if (closed || working) return
        val layer = layers.firstOrNull { it.id == id } ?: return
        val endpoint = AISettings.endpoint() ?: run {
            note = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        working = true
        note = null
        model.scope.launch {
            var made: ImageLayer? = null
            var failure: String? = null
            try {
                AIClient.takeLastUsage()
                val keyed = AIRunner.run(endpoint, Cutout.AI_PROMPT, layer.edited, emptyList(), emptyList(), null, appendGuidance = false)
                AIClient.takeLastUsage()
                made = withContext(Dispatchers.Default) {
                    val mask = Cutout.maskFromKeyed(keyed) ?: return@withContext null
                    val (l, ok) = layer.copy(mask = mask, cutout = true).rebuilt(editedChanged = false)
                    if (ok) l else null
                }
                if (made == null) failure = "AI 没有把背景分出来，可以再试一次。"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                failure = (e as? AIError)?.text ?: e.message ?: "请求失败。"
            }
            if (closed) return@launch
            working = false
            note = failure
            val m = made ?: return@launch
            val j = layers.indexOfFirst { it.id == id }
            if (j < 0) return@launch
            layers = layers.toMutableList().also {
                it[j] = it[j].copy(mask = m.mask, cutout = m.cutout, content = m.content, preview = m.preview)
            }
            changed = true
            render()
        }
    }

    fun setLayerFeather(id: String, value: Float) {
        rebuildLayer(id, editedChanged = false, failure = null) { it.copy(feather = value.coerceIn(0f, 1f)) }
    }

    /** 单独编辑完这个图层的内容，把新的修改步骤交回来。 */
    fun applyLayerEdit(id: String, ops: List<EditOp>) {
        rebuildLayer(id, editedChanged = true, failure = "改完以后本机没有识别到主体，去背景已关掉。") { it.copy(ops = ops) }
    }

    private fun rebuildLayer(id: String, editedChanged: Boolean, failure: String?, change: (ImageLayer) -> ImageLayer) {
        if (closed || working) return
        val i = layers.indexOfFirst { it.id == id }
        if (i < 0) return
        val wanted = layers[i].cutout
        val layer = change(layers[i])
        val wantsCutout = layer.cutout || wanted
        working = true
        note = null
        model.scope.launch {
            val (l, ok) = withContext(Dispatchers.Default) { layer.rebuilt(editedChanged) }
            if (closed) return@launch
            working = false
            val j = layers.indexOfFirst { it.id == id }
            if (j >= 0) {
                // 摆放可能在等的这会儿被改过，只换图不换位置。
                layers = layers.toMutableList().also {
                    it[j] = it[j].copy(
                        ops = l.ops, edited = l.edited, mask = l.mask, cutout = l.cutout,
                        feather = l.feather, content = l.content, preview = l.preview,
                    )
                }
            }
            if (!ok && wantsCutout) note = failure
            changed = true
            render()
        }
    }

    /** 单独编辑一个图层的内容。 */
    fun layerEditRequest(id: String): LayerEditRequest? {
        val layer = layers.firstOrNull { it.id == id } ?: return null
        return LayerEditRequest(layer.name, layer.original, layer.ops) { ops -> applyLayerEdit(id, ops) }
    }

    /** 单独编辑图层下面的那张照片。 */
    fun backgroundEditRequest(): LayerEditRequest? {
        val source = model.source ?: return null
        return LayerEditRequest("照片", source, prefix) { ops ->
            if (!closed) {
                prefix = ops
                changed = true
                rebuildBackground()
            }
        }
    }

    // MARK: AI 融合

    /** AI 融合：把下面的照片和所有图层交给 AI，融成一张自然的照片。完成后图层这一步和融合结果都写进历史，可以撤销。 */
    fun fuseLayers() {
        if (closed || working || layers.isEmpty()) return
        val proxy = model.proxy ?: return
        val endpoint = AISettings.endpoint() ?: run {
            note = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        val stack = LayerStack(layers)
        val visible = layers.filter { !it.hidden }.takeLast(3)
        val baseImage = background
        val pre = prefix
        val suf = suffix
        working = true
        fusing = true
        fuseStarted = System.currentTimeMillis()
        note = null
        fuseJob = model.scope.launch {
            try {
                // 底下的照片里有没有人：有人就以人为主角，整张照片的图层当背景。
                val personMask = withContext(Dispatchers.Default) { baseImage?.let { PersonSegmenter.mask(it) } }
                val hasPerson = personMask != null || withContext(Dispatchers.Default) {
                    baseImage?.let { FaceDetector.detect(it).isNotEmpty() } ?: false
                }
                val references = listOfNotNull(baseImage) + visible.map { it.content }
                AIClient.takeLastUsage()
                val result = AIRunner.run(
                    endpoint, fusePrompt(visible, hasPerson), proxy, pre + stack, emptyList(), null,
                    appendGuidance = false, references = references,
                )
                AIClient.takeLastUsage()
                // 有人、而且图层都是整张的场景（没有要放在人前面的抠图）：把原照片里的人原样贴回去，
                // 只借 AI 结果的光影和颜色，这样脸、胖瘦和手都是原图的，不会变也不会有重影。
                var final = result
                if (personMask != null && visible.none { it.cutout }) {
                    final = withContext(Dispatchers.Default) {
                        runCatching { restorePerson(result, EditOp.applyAll(pre, proxy), personMask) }
                            .onFailure { it.printStackTrace() }.getOrNull() ?: result
                    }
                }
                if (closed) return@launch
                working = false
                fusing = false
                // 历史：下面的照片 → 图层 → 融合结果 → 之后的步骤。
                if (suf.isEmpty()) {
                    // 先把图层这一步存下，再把融合结果放进 AI 结果面板，调好柔化再确认
                    model.replaceOps(pre + stack) {
                        (model.begin(Tool.AI) as? com.taoo.xiutu.ai.AISession)?.showFusedResult(final)
                    }
                } else {
                    model.replaceOps(pre + stack + AIEdit(final, emptyList(), soften = 0f) + suf)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                if (closed) return@launch
                working = false
                fusing = false
                note = (e as? AIError)?.text ?: e.message ?: "请求失败。"
            }
        }
    }

    companion object {
        /** 让图层整个落在画面里时的宽度比例。fill = 最多占画面的多少。 */
        fun fittingWidth(aspect: Float, canvasW: Float, canvasH: Float, fill: Float): Float {
            if (canvasW <= 0f || canvasH <= 0f || aspect <= 0f) return fill
            // 图层高度 = width * canvasW * aspect，不能超过 fill * canvasH。
            return min(fill, fill * canvasH / (canvasW * aspect))
        }

        /** 融合用的指令。按每一层是什么（抠好的主体还是整张照片）、底下的照片里有没有人来拼。 */
        fun fusePrompt(layers: List<ImageLayer>, baseHasPerson: Boolean): String {
            val lines = mutableListOf(
                "第 1 张图是把几张照片叠在一起的粗合成，位置只是大概摆的。请参考后面附的原图，把它们重新合成为一张真实、自然、像一次拍下来的照片。",
                "第 2 张图是最底下的原照片。",
            )
            if (baseHasPerson) {
                lines += "【最重要】原照片里的人物是这张照片的主角：人物在画面里的位置、大小、轮廓、姿势和手的位置都和第 2 张原照片完全一样，一个像素都不要挪，也不要重画人物；长相、脸型、胖瘦、发型和服装都不变。人物只有一个，不要出现重影或多出来的手。粗合成里如果有图层挡住了人，那是摆放的问题，不要照着挡。"
            }
            layers.forEachIndexed { i, layer ->
                val n = i + 3
                lines += when {
                    layer.cutout -> "第 $n 张图是抠好的主体（人或物体），要放进画面里、大致在粗合成里的位置，形状和细节不变。"
                    baseHasPerson -> "第 $n 张图是一张完整的场景照片：把它当成新的背景和环境，放在人物身后，让人物看起来就站在这个地方，人物脚下的地面和周围环境要和这个场景连贯。"
                    else -> "第 $n 张图是一张照片，按粗合成里的位置和大小把它的内容自然地融进画面。"
                }
            }
            lines += if (baseHasPerson) {
                "【构图】人物不动，只通过调整背景场景的位置、远近和大小来构图：场景里的地标（建筑、塔、山、月亮等）要完整、好看地出现在人物身后，不要被画面边缘切掉顶部，上方留出适当的天空，画面平衡。"
            } else {
                "【构图】像一位专业摄影师在现场重新取景：主体和场景里的地标都要完整、好看地放在画面里，地标不要被画面边缘切掉顶部，上方留出适当的天空，画面平衡，主体可以偏在一侧，不要放在死板的正中间；画面里不要画出网格、辅助线或取景框。"
            }
            lines += "统一所有元素的光线方向和强弱、色温色调、反差、景深虚实、清晰度和画质；给人和物体补上符合场景的阴影、反光和与地面的接触；修掉抠图的硬边、白边和残留背景，发丝边缘自然；按场景的透视让大小比例合理。画面比例和第 1 张一致。"
            lines += "附的原图只用来参考和保持细节，不要把它们原样拼贴进画面，也不要出现拼贴的边框。结果必须是一张真实的相机照片：清晰度和原照片一致，不要过度锐化、不要边缘白边、不要塑料感的皮肤和过高的饱和度，不要有 AI 生成感和插画感。"
            return lines.joinToString("\n")
        }

        /** 蒙版往外扩（可分离的最大值滤波）。 */
        private const val DILATE = Shaders.HEADER + """
uniform sampler2D src;
uniform vec2 src_size;
uniform vec2 dir;
uniform float radius;
void main() {
    int n = int(min(ceil(radius), 64.0));
    vec2 px = dir / src_size;
    float m = texture(src, uv).r;
    for (int i = 1; i <= 64; i++) {
        if (i > n) break;
        m = max(m, max(texture(src, uv + px * float(i)).r, texture(src, uv - px * float(i)).r));
    }
    o = vec4(m, m, m, 1.0);
}
"""

        /** 把原照片里的人贴回融合结果：人物的细节用原图，光影颜色跟着融合结果走；人物边缘往外扩一点再羽化，盖住 AI 留下的重影。 */
        fun restorePerson(fused: Bitmap, base: Bitmap, mask: Bitmap): Bitmap {
            // 不超过 4096，免得太占内存。
            val small = Img.downscale(Img.soft(base), 4096)
            val tw = small.width
            val th = small.height
            return Gpu.run {
                val original = upload(small)
                val ai = pass(Shaders.COPY, mapOf("src" to upload(Img.soft(fused))), width = tw, height = th)
                val person = ToneTransfer.apply(this, original, ai)
                val dim = max(tw, th).toFloat()
                var m = pass(Shaders.COPY, mapOf("src" to upload(Img.soft(mask))), width = tw, height = th)
                val r = dim * 0.006f
                m = pass(DILATE, mapOf("src" to m), mapOf("dir" to floatArrayOf(1f, 0f), "radius" to r), tw, th)
                m = pass(DILATE, mapOf("src" to m), mapOf("dir" to floatArrayOf(0f, 1f), "radius" to r), tw, th)
                // Core Image 的模糊半径约等于 σ；Gpu.blur 的半径是 2.5σ
                m = blur(m, dim * 0.004f * 2.5f)
                read(pass(Shaders.BLEND_MASK, mapOf("src" to ai, "fg" to person, "mask" to m), width = tw, height = th))
            }
        }
    }
}
