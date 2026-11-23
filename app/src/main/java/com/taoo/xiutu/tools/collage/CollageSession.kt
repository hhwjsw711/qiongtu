package com.taoo.xiutu.tools.collage

import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min

/** 模板列表里的一项：模板 + 用哪个画布比例。 */
class CollageChoice(val layout: CollageLayout, val ratio: CollageRatio) {
    val id: String get() = layout.id + "@" + ratio.name
}

/** 拼接时可以推的边。 */
sealed class StitchEdge {
    /** 第一张图的开头。 */
    data object Start : StitchEdge()
    /** 第 index 张和下一张之间的接缝。 */
    data class Seam(val index: Int) : StitchEdge()
    /** 最后一张图的结尾。 */
    data object End : StitchEdge()
}

/** 拼图工具打开期间的全部状态。 */
class CollageSession(model: EditorModel) : ToolSession(model, Tool.COLLAGE) {
    var params by mutableStateOf(CollageParams())
        private set
    /** 选中的是第几张图（模板里也就是第几格）。 */
    var selected by mutableStateOf<Int?>(null)
    /** 模板列表按哪个比例筛选；null = 全部。 */
    var ratioFilter by mutableStateOf<CollageRatio?>(null)
        private set
    /** 相册选择器是否要打开。 */
    var pickerShown by mutableStateOf(false)
    /** 不为空 = 选回来的图替换第几张；为空 = 加在后面。 */
    private var pickerReplace: Int? = null
    /** 这一次最多能选几张。 */
    var pickerLimit by mutableStateOf(8)
        private set
    /** 正在读取选回来的图。 */
    var loading by mutableStateOf(false)
        private set
    /** 面板底下的一句提示。 */
    var note by mutableStateOf<String?>(null)
        private set
    /** 长按拖动换位置：从哪一格拖到哪一格。 */
    var swapFrom by mutableStateOf<Int?>(null)
    var swapTo by mutableStateOf<Int?>(null)

    private var closed = false

    override val customCanvas: Boolean get() = true

    override fun start() = renderCollage()

    /** 点 ✓ 时要写进历史的那一步；没加别的图就什么都不加。 */
    override fun commitOps(): List<EditOp> = if (params.isIdentity) emptyList() else listOf(CollageOp(params))

    override fun close() {
        closed = true
    }

    @Composable
    override fun Canvas(modifier: Modifier) = CollageCanvas(this, modifier)

    @Composable
    override fun Panel() = CollagePanel(this)

    /** 正在编辑的图的尺寸（预览图的），排版时当作"第一张图"的尺寸。 */
    val reference: Pair<Float, Float>
        get() = model.base?.let { it.width.toFloat() to it.height.toFloat() } ?: (3f to 4f)

    /** 按当前参数重新拼一遍，显示到画布上。 */
    fun renderCollage() {
        if (closed) return
        val p = params
        model.liveOnBase { base -> p.render(base, preview = true) }
    }

    // MARK: 模板

    /** 面板里要列出来的模板。"全部"时每个模板按自己最合适的比例；选了比例就只列放得下的。 */
    val choices: List<CollageChoice>
        get() {
            val ratio = ratioFilter
            return if (ratio != null) CollageLayout.all.filter { it.fits(ratio) }.map { CollageChoice(it, ratio) }
            else CollageLayout.all.map { CollageChoice(it, it.natural) }
        }

    fun setMode(mode: CollageMode) {
        if (params.mode == mode) return
        params = params.copy(mode = mode)
        selected = null
        swapFrom = null
        swapTo = null
        if (mode == CollageMode.TEMPLATE) fitLayout()
        refreshNote()
        renderCollage()
    }

    fun applyRatioFilter(ratio: CollageRatio?) {
        ratioFilter = ratio
        if (ratio == null) return
        params = params.copy(ratio = ratio)
        if (!params.layout.fits(ratio)) params = params.copy(layout = bestLayout(params.pictures.size, ratio))
        refreshNote()
        renderCollage()
    }

    fun select(layout: CollageLayout, ratio: CollageRatio) {
        params = params.copy(layout = layout, ratio = ratio)
        selected?.let { if (it >= layout.cells.size) selected = null }
        refreshNote()
        renderCollage()
    }

    /** 这个比例下，格子数够放 count 张图的第一个模板；都不够就用格子最多的。 */
    private fun bestLayout(count: Int, ratio: CollageRatio): CollageLayout {
        val usable = CollageLayout.all.filter { it.fits(ratio) }
        return usable.firstOrNull { it.cells.size >= maxOf(count, 2) } ?: usable.lastOrNull() ?: CollageLayout.all[0]
    }

    /** 图比格子多的时候，自动换成格子够用的模板。 */
    private fun fitLayout() {
        val p = params
        if (p.pictures.size <= p.layout.cells.size) return
        params = p.copy(layout = bestLayout(p.pictures.size, p.ratio))
    }

    private fun refreshNote() {
        val hidden = params.hiddenCount
        note = if (hidden > 0) "这个模板放不下全部的图，还有 $hidden 张没显示。换个格子更多的模板，或者用“拼接”。" else null
    }

    // MARK: 样式

    fun setGap(v: Float) { params = params.copy(gap = v); renderCollage() }
    fun setCorner(v: Float) { params = params.copy(corner = v); renderCollage() }
    fun setMargin(v: Float) { params = params.copy(margin = v); renderCollage() }
    fun setBackground(c: CollageColor) { params = params.copy(background = c); renderCollage() }
    fun setStitchGap(v: Float) { params = params.copy(stitchGap = v); renderCollage() }

    // MARK: 加图 / 换图

    /** 点了画布：点的是图就选中（再点一下取消），点的是空格子就去相册加图。 */
    fun tap(index: Int) {
        if (index < params.pictures.size) {
            selected = if (selected == index) null else index
        } else {
            requestAdd()
        }
    }

    fun requestAdd() {
        val p = params
        pickerReplace = null
        if (p.mode == CollageMode.TEMPLATE) {
            val room = CollageLayout.maxCells - p.pictures.size
            if (room <= 0) {
                note = "模板最多放 ${CollageLayout.maxCells} 张图。想接更多张，用“拼接”。"
                return
            }
            pickerLimit = room
        } else {
            pickerLimit = 20
        }
        pickerShown = true
    }

    fun requestReplace(index: Int) {
        if (index !in params.pictures.indices) return
        pickerReplace = index
        pickerLimit = 1
        pickerShown = true
    }

    /** 相册里选好了：读出来，放进拼图。 */
    fun import(uris: List<Uri>) {
        if (uris.isEmpty() || closed) return
        val replace = pickerReplace
        loading = true
        note = null
        val context = model.context
        model.scope.launch {
            val loaded = withContext(Dispatchers.Default) { uris.mapNotNull { CollageImport.picture(context, it) } }
            if (closed) return@launch
            loading = false
            if (loaded.isEmpty()) {
                note = "这张图读不出来，换一张试试。"
                return@launch
            }
            if (replace != null && replace in params.pictures.indices) {
                params = params.copy(pictures = params.pictures.toMutableList().also { it[replace] = loaded[0] })
            } else {
                params = params.copy(pictures = params.pictures + loaded)
                if (params.mode == CollageMode.TEMPLATE) fitLayout()
            }
            refreshNote()
            if (loaded.size < uris.size) note = "有 ${uris.size - loaded.size} 张图读不出来，已跳过。"
            renderCollage()
        }
    }

    // MARK: 调整某一张

    private fun updatePicture(index: Int, change: (CollagePicture) -> CollagePicture) {
        if (index !in params.pictures.indices) return
        params = params.copy(pictures = params.pictures.toMutableList().also { it[index] = change(it[index]) })
        renderCollage()
    }

    fun remove(index: Int) {
        if (index !in params.pictures.indices) return
        params = params.copy(pictures = params.pictures.toMutableList().also { it.removeAt(index) })
        selected = null
        refreshNote()
        renderCollage()
    }

    private fun swapAt(a: Int, b: Int) {
        params = params.copy(pictures = params.pictures.toMutableList().also { val t = it[a]; it[a] = it[b]; it[b] = t })
    }

    /** 往前（-1）或往后（+1）挪一位。 */
    fun move(index: Int, step: Int) {
        val target = index + step
        if (index !in params.pictures.indices || target !in params.pictures.indices) return
        swapAt(index, target)
        selected = target
        renderCollage()
    }

    fun swap(a: Int, b: Int) {
        if (a == b || a !in params.pictures.indices || b !in params.pictures.indices) return
        swapAt(a, b)
        selected = b
        renderCollage()
    }

    fun flip(index: Int) = updatePicture(index) { it.copy(flip = !it.flip) }

    fun rotate(index: Int) = updatePicture(index) { it.copy(quarterTurns = (it.quarterTurns + 1) % 4) }

    /** 把图在格子里的位置和放大倍数还原成"居中铺满"。 */
    fun resetFit(index: Int) = updatePicture(index) { it.copy(ox = 0f, oy = 0f, zoom = 1f) }

    fun pan(index: Int, ox: Float, oy: Float) = updatePicture(index) { it.copy(ox = ox.coerceIn(-1f, 1f), oy = oy.coerceIn(-1f, 1f)) }

    fun zoom(index: Int, zoom: Float) = updatePicture(index) { it.copy(zoom = zoom.coerceIn(1f, 4f)) }

    // MARK: 拼接

    /** 自动拼图打开时：切到竖拼，第一张是正在编辑的这张，后面几张从文件读，按算好的位置裁好两头。 */
    fun loadAutoStitch(job: AutoStitchJob) {
        if (closed || job.files.size != job.cropStart.size || job.files.size != job.cropEnd.size) return
        setMode(CollageMode.STITCH)
        params = params.copy(vertical = true, stitchGap = 0f)
        loading = true
        val context = model.context
        model.scope.launch {
            val loaded = withContext(Dispatchers.Default) {
                job.files.drop(1).map { CollageImport.picture(context, android.net.Uri.fromFile(it)) }
            }
            if (closed) return@launch
            loading = false
            val pics = mutableListOf(CollagePicture(isBase = true))
            val starts = mutableListOf(job.cropStart[0])
            val ends = mutableListOf(job.cropEnd[0])
            loaded.forEachIndexed { k, picture ->
                if (picture == null) return@forEachIndexed
                pics += picture
                starts += job.cropStart[k + 1]
                ends += job.cropEnd[k + 1]
            }
            for (i in pics.indices) {
                val s0 = starts[i].coerceIn(0f, 0.95f)
                pics[i] = pics[i].copy(cropStart = s0, cropEnd = ends[i].coerceIn(0f, 0.95f - s0))
            }
            params = params.copy(pictures = pics)
            renderCollage()
            job.files.firstOrNull()?.parentFile?.deleteRecursively()
        }
    }

    fun setVertical(vertical: Boolean) {
        if (params.vertical == vertical) return
        params = params.copy(vertical = vertical)
        renderCollage()
    }

    // MARK: 拼接裁剪

    /**
     * 拼接时推一条边。moved 是从按下到现在沿拼接方向挪了多少（以图的宽 / 高为 1；竖拼向下、横拼向右为正），
     * start 是按下时的图。
     */
    fun stitchPush(edge: StitchEdge, moved: Float, start: List<CollagePicture>) {
        val (refW, refH) = reference
        val full = params.stitchFullLengths(refW, refH)
        if (start.size != full.size || start.isEmpty()) return
        val pics = start.toMutableList()
        fun clampStart(i: Int, v: Float) { pics[i] = pics[i].copy(cropStart = v.coerceIn(0f, max(0f, 0.95f - pics[i].cropEnd))) }
        fun clampEnd(i: Int, v: Float) { pics[i] = pics[i].copy(cropEnd = v.coerceIn(0f, max(0f, 0.95f - pics[i].cropStart))) }
        when (edge) {
            StitchEdge.Start -> clampStart(0, start[0].cropStart + moved / full[0])
            StitchEdge.End -> {
                val i = pics.size - 1
                clampEnd(i, start[i].cropEnd - moved / full[i])
            }
            is StitchEdge.Seam -> {
                val up = edge.index
                val down = up + 1
                if (down >= pics.size) return
                if (moved > 0) {
                    // 往下推：先把上面那张裁掉的放回来，放完了再裁下面那张的开头。
                    val giveBack = min(moved, start[up].cropEnd * full[up])
                    clampEnd(up, start[up].cropEnd - giveBack / full[up])
                    clampStart(down, start[down].cropStart + (moved - giveBack) / full[down])
                } else {
                    val m = -moved
                    val giveBack = min(m, start[down].cropStart * full[down])
                    clampStart(down, start[down].cropStart - giveBack / full[down])
                    clampEnd(up, start[up].cropEnd + (m - giveBack) / full[up])
                }
            }
        }
        params = params.copy(pictures = pics)
        renderCollage()
    }
}
