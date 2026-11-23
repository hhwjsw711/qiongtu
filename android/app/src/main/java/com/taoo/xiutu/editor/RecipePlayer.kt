package com.taoo.xiutu.editor

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.ai.AISession
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.ml.PersonSegmenter
import com.taoo.xiutu.tools.adjust.AdjustOp
import com.taoo.xiutu.tools.crop.CropOp
import com.taoo.xiutu.tools.effect.EffectOp
import com.taoo.xiutu.tools.filter.InstantOp
import com.taoo.xiutu.tools.filter.LookOp
import com.taoo.xiutu.tools.frame.BackdropOp
import com.taoo.xiutu.tools.frame.FrameOp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/**
 * 把另一张图的处理步骤，一步一步套到当前这张照片上。
 * 调色、滤镜、特效、裁剪、边框这类直接照搬参数；AI 那几步按原来的指令在这张照片上重新生成；
 * 和原图位置绑在一起的（涂抹、文字、涂鸦……）跳过。
 */
class RecipePlayer(private val model: EditorModel) {
    /** 正在套用时显示的进度，比如"3/7 AI 大师 · 滨田英明"；null = 没在套用。 */
    var status by mutableStateOf<String?>(null)
        private set
    private var job: Job? = null

    fun start(recipe: EditRecipe) {
        job?.cancel()
        job = model.scope.launch { play(recipe) }
    }

    fun stop() {
        job?.cancel()
        job = null
        (model.session as? AISession)?.let { if (it.running) it.cancelAI() }
        status = null
    }

    private suspend fun play(recipe: EditRecipe) {
        val steps = recipe.steps.filter { it.action != null }
        for ((i, step) in steps.withIndex()) {
            val action = step.action ?: break
            status = "${i + 1}/${steps.size} ${step.title}" + if (step.detail.isEmpty()) "" else " · ${step.detail}"
            // 等上一步彻底做完（底图重建好）再开始下一步。
            while (model.isLoading || model.isBusy || model.tool != null) delay(150)
            if (model.base == null) break
            if (action is RecipeAction.AI) {
                if (!replayAI(action)) {
                    // AI 这一步没做成：停在这里，面板上留着出错的原因。
                    status = null
                    job = null
                    return
                }
            } else {
                localOp(action)?.let { append(it) }
            }
        }
        status = null
        job = null
    }

    /** 本机那几步：照搬参数；裁剪按这张图的大小重新摆；特效需要主体蒙版的话按这张图重新算。 */
    private suspend fun localOp(action: RecipeAction): EditOp? = when (action) {
        is RecipeAction.Adjust -> AdjustOp(action.params)
        is RecipeAction.Look -> LookOp(action.id, action.intensity)
        is RecipeAction.Crop -> {
            val b = model.base
            CropOp(if (b == null) action.params else action.params.adapted(action.aspect, action.area, b.width, b.height))
        }
        is RecipeAction.Frame -> FrameOp(action.params)
        is RecipeAction.Backdrop -> BackdropOp(action.params)
        is RecipeAction.Instant -> InstantOp(action.params)
        is RecipeAction.Effect -> {
            var p = action.params
            val b = model.base
            if (p.kind?.usesMask == true && b != null) {
                val mask = withContext(Dispatchers.Default) {
                    runCatching { PersonSegmenter.mask(b)?.let { Img.downscale(it, MASK_SIDE) } }.getOrNull()
                }
                p = p.copy(mask = mask)
            }
            EffectOp(p)
        }
        is RecipeAction.AI -> null
    }

    /** 在历史末尾加一步，等底图重建好。 */
    private suspend fun append(op: EditOp) = suspendCancellableCoroutine { c ->
        model.replaceOps(model.ops + op) { if (c.isActive) c.resume(Unit) }
    }

    /** AI 那一步：打开 AI 修图，用原来的指令和设置重新生成，结果出来后按原来的强度、柔化确认。 */
    private suspend fun replayAI(action: RecipeAction.AI): Boolean {
        val r = action.recipe
        val group = AIPresetGroup.entries.firstOrNull { it.name == r.group } ?: return true
        model.beginAI(group, r.prompt)
        val s = model.session as? AISession ?: return false
        s.replay(r)
        while (s.running) delay(200)
        if (!s.hasResult || model.session !== s) return false
        s.applyReplayed(r)
        suspendCancellableCoroutine { c -> model.commitTool { if (c.isActive) c.resume(Unit) } }
        return true
    }

    private companion object {
        /** 和特效工具里算的主体蒙版一样大。 */
        const val MASK_SIDE = 1024
    }
}
