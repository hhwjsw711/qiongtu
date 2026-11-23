package com.taoo.xiutu.editor

import com.taoo.xiutu.tools.adjust.AdjustKey
import com.taoo.xiutu.tools.adjust.AdjustParams
import com.taoo.xiutu.tools.adjust.CurvePoint
import com.taoo.xiutu.tools.adjust.CurveSet
import com.taoo.xiutu.tools.adjust.LocalAdjust
import com.taoo.xiutu.tools.adjust.SplitTone
import com.taoo.xiutu.tools.color.V3
import com.taoo.xiutu.tools.crop.CropParams
import com.taoo.xiutu.tools.crop.CropRect
import com.taoo.xiutu.tools.effect.EffectParams
import com.taoo.xiutu.tools.filter.InstantBed
import com.taoo.xiutu.tools.filter.InstantFormat
import com.taoo.xiutu.tools.filter.InstantParams
import com.taoo.xiutu.tools.filter.InstantStock
import com.taoo.xiutu.tools.filter.PaperColor
import com.taoo.xiutu.tools.frame.BackdropFill
import com.taoo.xiutu.tools.frame.BackdropParams
import com.taoo.xiutu.tools.frame.BackdropRatio
import com.taoo.xiutu.tools.frame.FrameColor
import com.taoo.xiutu.tools.frame.FrameParams
import com.taoo.xiutu.tools.frame.FrameStyle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class RecipeTest {
    private fun sample(): EditRecipe {
        val adjust = AdjustParams()
            .with(AdjustKey.BRIGHTNESS, 0.3f).with(AdjustKey.TEMPERATURE, -0.2f)
            .copy(
                hsl = List(8) { if (it == 2) V3(0.1f, -0.2f, 0.3f) else V3.ZERO },
                curves = CurveSet().with(0, listOf(CurvePoint(0f, 0.05f), CurvePoint(0.5f, 0.6f), CurvePoint(1f, 1f))),
                split = SplitTone(shadowAmount = 0.4f, balance = 0.2f),
                locals = listOf(LocalAdjust(id = 3, cx = 0.3f, cy = 0.4f, brightness = 0.5f)),
            )
        val crop = CropParams(flip = true, quarterTurns = 1, straighten = 2.5f, rect = CropRect(0.1f, 0.2f, 0.5f, 0.6f))
        return EditRecipe(
            listOf(
                RecipeStep(title = "调色", detail = "亮度 +30", symbol = "slider.horizontal.3", action = RecipeAction.Adjust(adjust)),
                RecipeStep(title = "滤镜", symbol = "camera.filters", action = RecipeAction.Look("portra", 0.8f)),
                RecipeStep(title = "裁剪", symbol = "crop", action = RecipeAction.Crop(crop, 1.25f, 0.3f)),
                RecipeStep(
                    title = "边框", symbol = "photo.artframe",
                    action = RecipeAction.Frame(FrameParams(FrameStyle.POLAROID, FrameColor(0.9f, 0.8f, 0.7f), caption = "海边")),
                ),
                RecipeStep(
                    title = "背景", symbol = "photo.on.rectangle",
                    action = RecipeAction.Backdrop(BackdropParams(BackdropRatio.R4X5, scale = 0.8f, fill = BackdropFill.GRADIENT, colorB = FrameColor.black)),
                ),
                RecipeStep(
                    title = "拍立得", symbol = "photo",
                    action = RecipeAction.Instant(
                        InstantParams(InstantFormat.MINI, rotated = true, stock = InstantStock.SX70, paper = PaperColor(0.1f, 0.2f, 0.3f), real = true, bed = InstantBed.DARK),
                    ),
                ),
                RecipeStep(title = "特效", symbol = "sparkles.rectangle.stack", action = RecipeAction.Effect(EffectParams("bokeh", 0.6f, 1, 42))),
                RecipeStep(
                    title = "AI 大师", symbol = "sparkles",
                    action = RecipeAction.AI(AIRecipe("MASTER", "按大师风格修", "滨田英明", masterCompose = true, reframe = "PORTRAIT", strength = 0.7f, toneOnly = true, soften = 0.2f)),
                ),
                RecipeStep(title = "涂鸦", symbol = "scribble.variable"),
            ),
        )
    }

    @Test
    fun roundTrip() {
        val r = sample()
        val text = r.encode()
        val back = EditRecipe.decode(text)
        assertNotNull(back)
        assertEquals(r, back)
        assertEquals(8, back!!.copyable)
        assertNull(back.steps.last().action)
    }

    @Test
    fun effectMaskIsNotStored() {
        val text = EditRecipe(listOf(RecipeStep(title = "特效", symbol = "x", action = RecipeAction.Effect(EffectParams("bgBlur"))))).encode()
        assertTrue(!text.contains("mask"))
        val p = (EditRecipe.decode(text)!!.steps[0].action as RecipeAction.Effect).params
        assertNull(p.mask)
        assertEquals("bgBlur", p.id)
    }

    @Test
    fun unknownKeysAreIgnored() {
        val text = """{"steps":[{"id":"a","title":"滤镜","symbol":"camera.filters","extra":1,"action":{"type":"look","id":"x","intensity":0.5,"later":true}}]}"""
        val r = EditRecipe.decode(text)
        assertEquals(RecipeAction.Look("x", 0.5f), r!!.steps[0].action)
    }

    @Test
    fun badTextGivesNull() {
        assertNull(EditRecipe.decode("not json"))
    }

    private fun pixelAspect(p: CropParams, w: Int, h: Int): Float {
        val (ow, oh) = if (p.quarterTurns % 2 == 1) h to w else w to h
        return p.rect.w * ow / (p.rect.h * oh)
    }

    private fun near(a: Float, b: Float, eps: Float = 1e-3f) = assertTrue("$a vs $b", abs(a - b) < eps)

    @Test
    fun cropKeepsAspectCenterAndArea() {
        // 原图 4000×3000 上裁了一块 1:1、居中偏左、占 30%
        val src = CropParams(rect = CropRect(0.1f, 0.2f, 0.45f, 0.6f))
        val aspect = 0.45f * 4000 / (0.6f * 3000)
        val area = 0.45f * 0.6f
        val p = src.adapted(aspect, area, 3000, 4000)
        near(pixelAspect(p, 3000, 4000), aspect)
        near(p.rect.w * p.rect.h, area)
        near(p.rect.x + p.rect.w / 2, 0.1f + 0.45f / 2)
        near(p.rect.y + p.rect.h / 2, 0.2f + 0.6f / 2)
    }

    @Test
    fun cropShrinksWhenItDoesNotFit() {
        // 竖图上裁的一条很宽的横幅，套到另一张竖图上放不下：比例不变，缩小到放得下
        val src = CropParams(rect = CropRect(0f, 0.4f, 1f, 0.2f))
        val aspect = 1f * 1000 / (0.2f * 3000)
        val p = src.adapted(aspect, 0.2f, 1000, 1000)
        near(pixelAspect(p, 1000, 1000), aspect)
        assertTrue(p.rect.w <= 1f + 1e-4f && p.rect.h <= 1f + 1e-4f)
        assertTrue(p.rect.x >= 0f && p.rect.y >= 0f && p.rect.x + p.rect.w <= 1.0001f && p.rect.y + p.rect.h <= 1.0001f)
    }

    @Test
    fun cropFollowsRotation() {
        val src = CropParams(quarterTurns = 1, rect = CropRect(0.25f, 0.25f, 0.5f, 0.5f))
        val p = src.adapted(2f, 0.25f, 4000, 3000)
        assertEquals(1, p.quarterTurns)
        near(pixelAspect(p, 4000, 3000), 2f)
        near(p.rect.w * p.rect.h, 0.25f)
    }

    @Test
    fun uncroppedStaysUncropped() {
        val src = CropParams(quarterTurns = 2, flip = true)
        assertEquals(src, src.adapted(1.5f, 1f, 100, 200))
    }
}
