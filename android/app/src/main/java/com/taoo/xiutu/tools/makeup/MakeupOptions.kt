package com.taoo.xiutu.tools.makeup

import com.taoo.xiutu.ai.AIPreset
import com.taoo.xiutu.ai.currentLooks
import kotlin.math.abs

/** 美妆底部的大类。 */
enum class MakeupCategory(val title: String, val tabs: List<String>) {
    LOOK("妆容", emptyList()),
    LIP("口红", listOf("唇妆", "颜色", "质地", "晕染", "唇线")),
    BROW("眉毛", listOf("眉形", "颜色")),
    EYE("眼妆", listOf("眼妆", "眼影", "眼线", "睫毛", "卧蚕", "美瞳", "双眼皮", "眼神光")),
    CONTOUR("修容", listOf("立体", "高光", "阴影", "雀斑", "痣")),
    BLUSH("腮红", listOf("套装", "颜色", "部位", "质地")),
    NAIL("美甲", emptyList()),
    DECOR("装饰", listOf("面部", "纹身贴"));

    /** 美甲和装饰交给 AI，不需要在本机找脸。 */
    val isLocal: Boolean get() = this != NAIL && this != DECOR
}

/** 缩略图取脸上的哪一块。 */
enum class MakeupCrop { FACE, EYE, LIPS }

/** 面板上的一个选项。 */
class MakeupOption(
    val id: String,
    val title: String,
    val kind: Kind = Kind.Thumb,
    val selected: Boolean = false,
    /** 点一下以后怎么改这张脸的妆。 */
    val apply: (FaceMakeup) -> FaceMakeup = { it },
    /** 缩略图上画什么（画在一张没上妆的脸上）。 */
    val preview: (FaceMakeup) -> FaceMakeup = { it },
    /** 整套预设选中后记到哪个槽位：高亮用，浓淡滑块也靠它知道在调哪一套。 */
    val slot: String? = null,
    /** 修容里的高光 / 阴影分区：点了以后滑块调的就是这一区。 */
    val zone: String? = null,
    /** 点了以后进入或退出"在脸上点痣"。 */
    val togglesMolePlacing: Boolean = false,
) {
    sealed class Kind {
        /** 用这张脸渲染出来的缩略图。 */
        data object Thumb : Kind()
        /** 色块。 */
        data class Swatch(val color: MakeupColor) : Kind()
        /** 图标按钮。 */
        data class Symbol(val symbol: String) : Kind()
        /** 交给 AI 做的。 */
        data class Ai(val preset: AIPreset) : Kind()
    }
}

/** 美妆面板每一页上摆哪些选项。 */
fun MakeupSession.makeupOptions(): Pair<List<MakeupOption>, MakeupCrop> {
    val m = current
    return when (category) {
        MakeupCategory.LOOK -> lookOptions(m) to MakeupCrop.FACE
        MakeupCategory.LIP -> lipOptions(m) to MakeupCrop.LIPS
        MakeupCategory.BROW -> browOptions(m) to MakeupCrop.EYE
        MakeupCategory.EYE -> eyeOptions(m) to MakeupCrop.EYE
        MakeupCategory.CONTOUR -> contourOptions(m) to MakeupCrop.FACE
        MakeupCategory.BLUSH -> blushOptions(m) to MakeupCrop.FACE
        MakeupCategory.NAIL -> MakeupAI.nails.map { MakeupOption(it.title, it.title, MakeupOption.Kind.Ai(it)) } to MakeupCrop.FACE
        MakeupCategory.DECOR -> {
            val list = if (tab == 0) MakeupAI.face else MakeupAI.tattoo
            list.map { MakeupOption(it.title, it.title, MakeupOption.Kind.Ai(it)) } to MakeupCrop.FACE
        }
    }
}

private fun none(title: String = "原图", selected: Boolean, slot: String? = null, apply: (FaceMakeup) -> FaceMakeup) =
    MakeupOption("none", title, selected = selected, apply = apply, slot = slot)

// MARK: 妆容

private fun MakeupSession.lookOptions(m: FaceMakeup?): List<MakeupOption> {
    val list = arrayListOf(none(selected = m?.isEmpty ?: true, slot = "look") { face ->
        face.copy(lip = null, brow = null, eye = EyeMakeup(), contour = ContourMakeup(), blush = null)
    })
    for (look in MakeupCatalog.currentLooks) {
        list += MakeupOption(look.name, look.name, selected = pick("look") == look.name,
            apply = { it.applying(look, 1f) }, preview = { it.applying(look, 1f) }, slot = "look")
    }
    return list
}

// MARK: 口红

private fun MakeupSession.lipOptions(m: FaceMakeup?): List<MakeupOption> {
    val lip = m?.lip
    val fallback = MakeupCatalog.lipColor("豆沙")
    fun edit(face: FaceMakeup, change: (LipMakeup) -> LipMakeup): FaceMakeup {
        var value = face.lip ?: LipMakeup(fallback)
        if (value.amount <= 0) value = value.copy(amount = 0.8f)
        return face.copy(lip = change(value))
    }
    return when (tab) {
        0 -> {
            val list = arrayListOf(none(selected = lip == null, slot = "lip") { it.copy(lip = null) })
            for (preset in MakeupCatalog.lipPresets) {
                list += MakeupOption(preset.name, preset.name, selected = lip != null && pick("lip") == preset.name,
                    apply = { it.copy(lip = preset.lip) }, preview = { it.copy(lip = preset.lip) }, slot = "lip")
            }
            list
        }
        1 -> MakeupCatalog.lipColors.map { swatch ->
            MakeupOption(swatch.name, swatch.name, MakeupOption.Kind.Swatch(swatch.color), selected = lip?.color == swatch.color,
                apply = { face -> edit(face) { it.copy(color = swatch.color) } })
        }
        2 -> MKLipTexture.entries.map { texture ->
            MakeupOption("t${texture.ordinal}", texture.title, selected = lip?.texture == texture,
                apply = { face -> edit(face) { it.copy(texture = texture) } },
                preview = { it.copy(lip = LipMakeup(MakeupCatalog.lipColor("斩男色"), texture = texture)) })
        }
        3 -> MKLipStyle.entries.map { style ->
            MakeupOption("s${style.ordinal}", style.title, selected = lip?.style == style,
                apply = { face -> edit(face) { it.copy(style = style) } },
                preview = { it.copy(lip = LipMakeup(MakeupCatalog.lipColor("斩男色"), style = style)) })
        }
        else -> listOf("无" to 0f, "自然" to 0.5f, "明显" to 1f).map { (name, value) ->
            MakeupOption("l$name", name, selected = lip != null && abs((lip.liner) - value) < 0.02f,
                apply = { face -> edit(face) { it.copy(liner = value) } },
                preview = { it.copy(lip = LipMakeup(MakeupCatalog.lipColor("复古红"), texture = MKLipTexture.MATTE, liner = value)) })
        }
    }
}

// MARK: 眉毛

private fun MakeupSession.browOptions(m: FaceMakeup?): List<MakeupOption> {
    val brow = m?.brow
    if (tab == 1) {
        return MakeupCatalog.browColors.map { swatch ->
            MakeupOption(swatch.name, swatch.name, MakeupOption.Kind.Swatch(swatch.color), selected = brow?.color == swatch.color,
                apply = { face -> face.copy(brow = (face.brow ?: MakeupCatalog.browPreset(MKBrowShape.NATURAL)).copy(color = swatch.color)) })
        }
    }
    val list = arrayListOf(none(selected = brow == null) { it.copy(brow = null) })
    for (shape in MKBrowShape.entries) {
        list += MakeupOption("b${shape.ordinal}", shape.title, selected = brow?.shape == shape,
            apply = { face ->
                var value = MakeupCatalog.browPreset(shape)
                // 已经挑过颜色、调过浓淡的话，换眉形时保留
                face.brow?.let { old -> value = value.copy(color = old.color, amount = old.amount) }
                face.copy(brow = value)
            },
            preview = { it.copy(brow = MakeupCatalog.browPreset(shape).copy(amount = 0.75f)) })
    }
    return list
}

// MARK: 眼妆

private fun MakeupSession.eyeOptions(m: FaceMakeup?): List<MakeupOption> {
    val eye = m?.eye ?: EyeMakeup()
    fun FaceMakeup.eye(change: (EyeMakeup) -> EyeMakeup) = copy(eye = change(this.eye))
    return when (tab) {
        0 -> {
            val list = arrayListOf(none(selected = eye.isEmpty, slot = "eye") { it.copy(eye = EyeMakeup()) })
            for (preset in MakeupCatalog.eyePresets) {
                list += MakeupOption(preset.name, preset.name, selected = !eye.isEmpty && pick("eye") == preset.name,
                    apply = { it.copy(eye = preset.eye) }, preview = { it.copy(eye = preset.eye) }, slot = "eye")
            }
            list
        }
        1 -> {
            val list = arrayListOf(none("无", selected = eye.shadow == null) { f -> f.eye { it.copy(shadow = null) } })
            for (preset in MakeupCatalog.shadows) {
                val on = eye.shadow?.let { it.lid == preset.shadow.lid && it.crease == preset.shadow.crease && it.outer == preset.shadow.outer } ?: false
                list += MakeupOption(preset.name, preset.name, selected = on,
                    apply = { f ->
                        f.eye { e ->
                            var value = preset.shadow
                            e.shadow?.let { old -> value = value.copy(amount = old.amount) }
                            e.copy(shadow = value)
                        }
                    },
                    preview = { f -> f.eye { it.copy(shadow = preset.shadow.copy(amount = 0.85f)) } })
            }
            list
        }
        2 -> {
            val list = arrayListOf(none("无", selected = eye.liner == null) { f -> f.eye { it.copy(liner = null) } })
            for (style in MKLinerStyle.entries) {
                list += MakeupOption("l${style.ordinal}", style.title, selected = eye.liner?.style == style,
                    apply = { f -> f.eye { e -> e.copy(liner = (e.liner ?: LinerMakeup(style)).copy(style = style)) } },
                    preview = { f -> f.eye { it.copy(liner = LinerMakeup(style)) } })
            }
            for (swatch in MakeupCatalog.linerColors) {
                list += MakeupOption("c" + swatch.name, swatch.name, MakeupOption.Kind.Swatch(swatch.color),
                    selected = eye.liner?.color == swatch.color,
                    apply = { f -> f.eye { e -> e.copy(liner = (e.liner ?: LinerMakeup(MKLinerStyle.NATURAL)).copy(color = swatch.color)) } })
            }
            list
        }
        3 -> {
            val list = arrayListOf(none("无", selected = eye.lashes == null) { f -> f.eye { it.copy(lashes = null) } })
            for (style in MKLashStyle.entries) {
                list += MakeupOption("h${style.ordinal}", style.title, selected = eye.lashes?.style == style,
                    apply = { f -> f.eye { e -> e.copy(lashes = (e.lashes ?: LashMakeup(style)).copy(style = style)) } },
                    preview = { f -> f.eye { it.copy(lashes = LashMakeup(style, 1f)) } })
            }
            list
        }
        4 -> listOf("无" to 0f, "自然" to 0.5f, "明显" to 0.9f).map { (name, value) ->
            MakeupOption("a$name", name, selected = abs(eye.aegyo - value) < 0.02f,
                apply = { f -> f.eye { it.copy(aegyo = value) } }, preview = { f -> f.eye { it.copy(aegyo = value) } })
        }
        5 -> {
            val list = arrayListOf(none("无", selected = eye.lens == null) { f -> f.eye { it.copy(lens = null) } })
            for (swatch in MakeupCatalog.lensColors) {
                list += MakeupOption(swatch.name, swatch.name, selected = eye.lens?.color == swatch.color,
                    apply = { f -> f.eye { e -> e.copy(lens = (e.lens ?: LensMakeup(swatch.color)).copy(color = swatch.color)) } },
                    preview = { f -> f.eye { it.copy(lens = LensMakeup(swatch.color, 0.75f)) } })
            }
            list
        }
        6 -> {
            val list = arrayListOf(none("无", selected = eye.foldAmount <= 0) { f -> f.eye { it.copy(foldAmount = 0f) } })
            for (style in MKFoldStyle.entries) {
                list += MakeupOption("f${style.ordinal}", style.title, selected = eye.foldAmount > 0 && eye.fold == style,
                    apply = { f -> f.eye { e -> e.copy(fold = style, foldAmount = if (e.foldAmount <= 0) 0.7f else e.foldAmount) } },
                    preview = { f -> f.eye { it.copy(fold = style, foldAmount = 1f) } })
            }
            list
        }
        else -> {
            val list = arrayListOf(none("无", selected = eye.catchlightAmount <= 0) { f -> f.eye { it.copy(catchlightAmount = 0f) } })
            for (style in MKCatchlight.entries) {
                list += MakeupOption("g${style.ordinal}", style.title, selected = eye.catchlightAmount > 0 && eye.catchlight == style,
                    apply = { f ->
                        f.eye { e -> e.copy(catchlight = style, catchlightAmount = if (e.catchlightAmount <= 0) 0.75f else e.catchlightAmount) }
                    },
                    preview = { f -> f.eye { it.copy(catchlight = style, catchlightAmount = 1f) } })
            }
            list
        }
    }
}

// MARK: 修容

private fun MakeupSession.contourOptions(m: FaceMakeup?): List<MakeupOption> {
    val c = m?.contour ?: ContourMakeup()
    fun FaceMakeup.contour(change: (ContourMakeup) -> ContourMakeup) = copy(contour = change(this.contour))
    return when (tab) {
        0 -> {
            val list = arrayListOf(none(selected = c.sculptIsEmpty, slot = "sculpt") { f -> f.contour { it.withSculpt(ContourMakeup()) } })
            for (preset in MakeupCatalog.contourPresets) {
                list += MakeupOption(preset.name, preset.name, selected = !c.sculptIsEmpty && pick("sculpt") == preset.name,
                    apply = { f -> f.contour { it.withSculpt(preset.contour) } },
                    preview = { f -> f.contour { it.withSculpt(preset.contour).scaledSculpt(1.25f) } },
                    slot = "sculpt")
            }
            list
        }
        1, 2 -> {
            val zones = if (tab == 1)
                listOf("forehead" to "额头", "noseLight" to "鼻梁", "cheekLight" to "颧骨", "chinLight" to "下巴", "cupid" to "唇峰", "underEye" to "眼下")
            else listOf("noseShade" to "鼻影", "jaw" to "下颌", "cheekShade" to "颧下", "temple" to "额角")
            val ids = zones.map { it.first }
            val list = arrayListOf(none("无", selected = ids.all { MakeupSession.zoneValue(it, c) <= 0 }) { f ->
                f.contour { var x = it; for (id in ids) x = MakeupSession.setZone(id, 0f, x); x }
            })
            for ((id, name) in zones) {
                val value = MakeupSession.zoneValue(id, c)
                list += MakeupOption(id, if (value > 0) "$name ✓" else name, selected = zone == id,
                    apply = { f ->
                        // 第一次点是打开这一区；已经开着的话只是选中它，用滑块调
                        if (MakeupSession.zoneValue(id, f.contour) <= 0) f.contour { MakeupSession.setZone(id, 0.7f, it) } else f
                    },
                    preview = { f -> f.contour { MakeupSession.setZone(id, 1f, it) } }, zone = id)
            }
            list
        }
        3 -> {
            val list = arrayListOf(none("无", selected = c.freckleAmount <= 0) { f -> f.contour { it.copy(freckleAmount = 0f) } })
            for (style in MKFreckleStyle.entries) {
                list += MakeupOption("k${style.ordinal}", style.title, selected = c.freckleAmount > 0 && c.freckles == style,
                    apply = { f ->
                        f.contour { it.copy(freckles = style, freckleAmount = if (it.freckleAmount <= 0) 0.6f else it.freckleAmount) }
                    },
                    preview = { f -> f.contour { it.copy(freckles = style, freckleAmount = 1f) } })
            }
            list
        }
        else -> {
            val list = arrayListOf(none("无", selected = c.moles.isEmpty()) { f -> f.contour { it.copy(moles = emptyList()) } })
            for (spot in MKMoleSpot.presets) {
                list += MakeupOption("m" + spot.title, spot.title, selected = spot in c.moles,
                    apply = { f -> f.contour { it.copy(moles = if (spot in it.moles) it.moles - spot else it.moles + spot) } },
                    preview = { f -> f.contour { it.copy(moles = listOf(spot)) } })
            }
            list += MakeupOption("place", "自己点", MakeupOption.Kind.Symbol("hand.tap"), selected = placingMole, togglesMolePlacing = true)
            list
        }
    }
}

// MARK: 腮红

private fun MakeupSession.blushOptions(m: FaceMakeup?): List<MakeupOption> {
    val blush = m?.blush
    val fallback = MakeupCatalog.blushColor("蜜桃")
    fun edit(face: FaceMakeup, change: (BlushMakeup) -> BlushMakeup): FaceMakeup {
        var value = face.blush ?: BlushMakeup(fallback)
        if (value.amount <= 0) value = value.copy(amount = 0.55f)
        return face.copy(blush = change(value))
    }
    return when (tab) {
        0 -> {
            val list = arrayListOf(none(selected = blush == null, slot = "blush") { it.copy(blush = null) })
            for (preset in MakeupCatalog.blushPresets) {
                list += MakeupOption(preset.name, preset.name, selected = blush != null && pick("blush") == preset.name,
                    apply = { it.copy(blush = preset.blush) },
                    preview = { it.copy(blush = preset.blush.copy(amount = minOf(1f, preset.blush.amount * 1.3f))) },
                    slot = "blush")
            }
            list
        }
        1 -> MakeupCatalog.blushColors.map { swatch ->
            MakeupOption(swatch.name, swatch.name, MakeupOption.Kind.Swatch(swatch.color), selected = blush?.color == swatch.color,
                apply = { face -> edit(face) { it.copy(color = swatch.color) } })
        }
        2 -> MKBlushPlacement.entries.map { placement ->
            MakeupOption("p${placement.ordinal}", placement.title, selected = blush?.placement == placement,
                apply = { face -> edit(face) { it.copy(placement = placement) } },
                preview = { it.copy(blush = BlushMakeup(MakeupCatalog.blushColor("玫瑰"), placement, amount = 0.8f)) })
        }
        else -> listOf(false, true).map { glow ->
            MakeupOption(if (glow) "glow" else "matte", if (glow) "光泽" else "哑光", selected = blush != null && blush.glow == glow,
                apply = { face -> edit(face) { it.copy(glow = glow) } },
                preview = { it.copy(blush = BlushMakeup(MakeupCatalog.blushColor("樱花粉"), glow = glow, amount = 0.8f)) })
        }
    }
}

/** 没法只靠五官位置画出来的那些：美甲、酒窝、饰品、纹身贴，交给 AI。 */
object MakeupAI {
    private fun nail(title: String, style: String) = AIPreset(
        title = title, symbol = "hand.raised.fingers.spread",
        prompt = "给画面里露出来的每一个指甲做美甲：$style。只改指甲表面的颜色和图案；指甲的形状和长度、手的姿势和位置、肤色，以及画面里其他所有东西都保持不变。画面里看不到指甲就什么都不要改。",
    )

    val nails: List<AIPreset> = listOf(
        nail("裸粉", "通透的裸粉色，薄涂，有健康的光泽"),
        nail("奶白", "柔和的奶白色，干净饱满"),
        nail("法式", "裸色底配细细的白色法式边"),
        nail("酒红", "浓郁的酒红色，亮面"),
        nail("猫眼", "灰紫色猫眼，中间一道流动的银色光带"),
        nail("腮红甲", "透明裸色底，指甲中间晕开一小团粉色腮红"),
        nail("冰透", "冰透的浅蓝色果冻质感"),
        nail("碎钻", "透粉色底，靠近甲根点缀几颗细小的碎钻"),
        nail("纯黑", "亮面纯黑色，短甲"),
        nail("樱花", "半透明樱花粉，带极细的闪粉"),
    )

    private fun face(title: String, symbol: String, what: String) = AIPreset(
        title = title, symbol = symbol,
        prompt = "$what。只加这一样，五官的形状和位置、表情、妆容、肤色、发型和其他所有东西都保持不变，必须还是同一个人，看起来像照片里本来就有的。",
        faceCrop = true,
    )

    val face: List<AIPreset> = listOf(
        face("小酒窝", "face.smiling", "在两边脸颊各加一个自然的小酒窝"),
        face("梨涡", "mouth", "在两边嘴角外侧各加一个小小的梨涡"),
        face("鼻钉", "circle.fill", "在一侧鼻翼上加一颗很小的银色鼻钉"),
        face("眉尾钉", "diamond", "在一侧眉尾加一枚小巧的银色眉钉"),
        face("唇钉", "circle.fill", "在下唇一侧加一枚小小的银色唇钉"),
        face("泪钻", "sparkle", "在两只眼睛的下眼角各贴两三颗细小的水钻"),
        face("脸颊爱心", "heart", "在一侧颧骨上贴一颗很小的红色爱心面贴"),
        face("星星面贴", "star.fill", "在一侧眼尾下方贴两三颗很小的银色星星面贴"),
    )

    private fun tattoo(title: String, symbol: String, what: String) = AIPreset(
        title = title, symbol = symbol,
        prompt = "$what，像一枚贴上去的纹身贴：线条细致，顺着皮肤的起伏和明暗，被衣服或头发挡住的地方不要画出来。那个部位在画面里看不到就什么都不要改。人物的长相、姿势、服装和画面里其他所有东西都保持不变。",
    )

    val tattoo: List<AIPreset> = listOf(
        tattoo("锁骨蝴蝶", "leaf", "在一侧锁骨下方加一只小小的黑色线条蝴蝶"),
        tattoo("锁骨英文", "textformat", "沿着一侧锁骨加一行纤细的黑色手写英文花体字"),
        tattoo("手臂玫瑰", "camera.macro", "在一只上臂外侧加一朵黑色线条的玫瑰"),
        tattoo("颈侧星月", "moon.stars", "在脖子侧面加一个很小的月亮和两三颗星星"),
        tattoo("手腕小花", "camera.macro", "在一只手腕内侧加一朵很小的线条小花"),
        tattoo("肩头藤蔓", "leaf", "在一侧肩头加一小段纤细的藤蔓叶子"),
    )
}
