package com.taoo.xiutu.tools.overlay

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.TextStarter
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import java.util.UUID

/** 文字、贴纸、形状三个工具共用：画面上的全部文字、贴纸、形状一起编辑，确认时合成一步。 */
class OverlaySession(model: EditorModel, tool: Tool) : ToolSession(model, tool), TextStarter {
    var items by mutableStateOf<List<OverlayItem>>(emptyList())
        private set
    var selectedId by mutableStateOf<String?>(null)

    /** 重新打开时的样子：没改过就原样保留。 */
    private var reopened: List<OverlayItem>? = null

    val selected: OverlayItem? get() = selectedId?.let { id -> items.firstOrNull { it.id == id } }

    override fun start() {
        FontStore.init(model.context)
        StickerStore.init(model.context)
    }

    override fun reopenMerged(ops: List<EditOp>, selecting: String?) {
        items = ops.flatMap { (it as? OverlayOp)?.items ?: emptyList() }
        reopened = items
        selectedId = selecting
    }

    private fun kept(): List<OverlayItem> = items.filter { it.text.isNotBlank() }

    override fun unchangedSinceReopen(): Boolean = reopened?.let { it == kept() } ?: false

    override fun commitOps(): List<EditOp> = kept().let { if (it.isEmpty()) emptyList() else listOf(OverlayOp(it)) }

    override fun onOpenedFromMenu() {
        // 已经有文字时是回来改它们，不自动弹出新文字的输入框
        if (tool == Tool.TEXT && items.isEmpty()) addText()
    }

    override val customCanvas: Boolean get() = true

    @Composable
    override fun Canvas(modifier: Modifier) = OverlayCanvas(this, modifier)

    @Composable
    override fun Panel() {
        when (tool) {
            Tool.TEXT -> TextPanel(this)
            Tool.GRAPHIC -> GraphicPanel(this)
            else -> StickerPanel(this)
        }
    }

    // MARK: 增删改

    /** 新加的项稍微错开一点，不会正好叠在上一个上面。 */
    private fun place(item: OverlayItem): OverlayItem {
        val n = (items.size % 5).toFloat()
        return item.copy(cx = 0.5f + n * 0.03f, cy = 0.5f + n * 0.03f)
    }

    private fun append(item: OverlayItem): String {
        items = items + item
        selectedId = item.id
        return item.id
    }

    fun addOverlay(text: String, sticker: Boolean): String {
        var item = OverlayItem(text = text, isSticker = sticker, size = if (sticker) 0.18f else 0.07f)
        if (!sticker) {
            // 接着用上一段文字的字体和样式，不用每次重新调
            items.lastOrNull { !it.isSticker }?.let { last ->
                item = last.copy(id = item.id, text = text, scale = 1f, rotation = 0f, size = item.size)
            }
        }
        return append(place(item))
    }

    /** 加一张图片贴纸。dieCut = true 时带白边和一点阴影，像真的贴纸。 */
    fun addOverlay(image: Bitmap, dieCut: Boolean = false): String {
        val aspect = image.width.toFloat() / maxOf(image.height, 1)
        var item = OverlayItem(
            text = OverlayItem.IMAGE_PLACEHOLDER, isSticker = true, image = OverlayImage(image),
            // 宽度占画面的三成左右；特别瘦高的图再小一点
            size = if (aspect < 0.7f) 0.22f else 0.3f,
        )
        if (dieCut) {
            item = item.copy(
                strokeOn = true, strokeColor = OverlayColor.white, strokeWidth = 0.5f,
                shadowOn = true, shadowColor = OverlayColor.black, shadowOpacity = 0.4f, shadowBlur = 0.6f,
                shadowDistance = 0.25f, shadowAngle = 90f,
            )
        }
        return append(place(item))
    }

    /** 加一个已经配好样式的项（标签贴纸用）。 */
    fun addOverlay(template: OverlayItem): String =
        append(place(template.copy(id = UUID.randomUUID().toString(), scale = 1f, rotation = 0f)))

    /** 加一个形状。默认是一条半透明的黑色横条（做字幕条、标签底最常用）。 */
    fun addGraphic(kind: GraphicKind): String {
        val g = GraphicStyle(kind = kind, sides = if (kind == GraphicKind.STAR) 5 else 6)
        val base = OverlayItem(text = OverlayItem.IMAGE_PLACEHOLDER, isSticker = true)
        val item = when (kind) {
            GraphicKind.RECT -> base.copy(graphic = g.copy(aspect = 0.22f), size = 0.8f, color = OverlayColor.black, opacity = 0.6f)
            GraphicKind.ARROW -> base.copy(graphic = g.copy(aspect = 0.45f), size = 0.4f, color = OverlayColor.of(1.0, 0.27, 0.27))
            GraphicKind.BUBBLE -> base.copy(graphic = g.copy(aspect = 0.7f), size = 0.45f, color = OverlayColor.white)
            else -> base.copy(graphic = g, size = 0.35f, color = OverlayColor.of(1.0, 0.84, 0.04))
        }
        return append(place(item))
    }

    fun update(id: String, change: (OverlayItem) -> OverlayItem) {
        items = items.map { if (it.id == id) change(it) else it }
    }

    /** 改选中的那一项。 */
    fun change(body: (OverlayItem) -> OverlayItem) {
        selectedId?.let { update(it, body) }
    }

    fun remove(id: String) {
        items = items.filter { it.id != id }
        if (selectedId == id) selectedId = null
    }

    /** 复制一份，放在旁边并选中。 */
    fun duplicate(id: String) {
        val source = items.firstOrNull { it.id == id } ?: return
        val copy = source.copy(
            id = UUID.randomUUID().toString(),
            cx = minOf(source.cx + 0.05f, 1.05f), cy = minOf(source.cy + 0.05f, 1.05f),
        )
        append(copy)
    }

    // MARK: 文字输入

    fun addText() {
        val id = addOverlay("", sticker = false)
        editText(id)
    }

    fun editText(id: String) {
        val current = items.firstOrNull { it.id == id }?.text ?: ""
        model.requestText(current, "输入文字") { finishTextEditing(id, it) }
    }

    private fun finishTextEditing(id: String, text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) remove(id) else update(id) { it.copy(text = trimmed) }
    }
}
