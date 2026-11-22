import SwiftUI
import UIKit

/// 美妆面板每一页上摆哪些选项。
extension EditorModel {
    func makeupOptions() -> (list: [MakeupOption], crop: MakeupOption.Crop) {
        let state = makeupState
        let m = state.current
        switch state.category {
        case .look: return (lookOptions(state, m), .face)
        case .lip: return (lipOptions(state, m), .lips)
        case .brow: return (browOptions(state, m), .eye)
        case .eye: return (eyeOptions(state, m), .eye)
        case .contour: return (contourOptions(state, m), .face)
        case .blush: return (blushOptions(state, m), .face)
        case .nail: return (MakeupAI.nails.map { MakeupOption(id: $0.title, title: $0.title, kind: .ai($0)) }, .face)
        case .decor:
            let list = state.tab == 0 ? MakeupAI.face : MakeupAI.tattoo
            return (list.map { MakeupOption(id: $0.title, title: $0.title, kind: .ai($0)) }, .face)
        }
    }

    private func none(_ title: String = "原图", selected: Bool, slot: String? = nil,
                      _ apply: @escaping (inout FaceMakeup) -> Void) -> MakeupOption {
        MakeupOption(id: "none", title: title, selected: selected, apply: apply, slot: slot)
    }

    // MARK: 妆容

    private func lookOptions(_ state: MakeupState, _ m: FaceMakeup?) -> [MakeupOption] {
        var list = [none(selected: m?.isEmpty ?? true, slot: "look") { face in
            face.lip = nil; face.brow = nil; face.eye = EyeMakeup(); face.contour = ContourMakeup(); face.blush = nil
        }]
        for look in MakeupCatalog.currentLooks {
            list.append(MakeupOption(id: look.name, title: look.name, selected: state.pick("look") == look.name,
                                     apply: { $0.apply(look, strength: 1) }, preview: { $0.apply(look, strength: 1) },
                                     slot: "look"))
        }
        return list
    }

    // MARK: 口红

    private func lipOptions(_ state: MakeupState, _ m: FaceMakeup?) -> [MakeupOption] {
        let lip = m?.lip
        let fallback = MakeupCatalog.lipColor("豆沙")
        func edit(_ face: inout FaceMakeup, _ change: (inout LipMakeup) -> Void) {
            var value = face.lip ?? LipMakeup(color: fallback)
            if value.amount <= 0 { value.amount = 0.8 }
            change(&value)
            face.lip = value
        }
        switch state.tab {
        case 0:
            var list = [none(selected: lip == nil, slot: "lip") { $0.lip = nil }]
            for preset in MakeupCatalog.lipPresets {
                list.append(MakeupOption(id: preset.name, title: preset.name, selected: lip != nil && state.pick("lip") == preset.name,
                                         apply: { $0.lip = preset.lip }, preview: { $0.lip = preset.lip }, slot: "lip"))
            }
            return list
        case 1:
            return MakeupCatalog.lipColors.map { swatch in
                MakeupOption(id: swatch.name, title: swatch.name, kind: .swatch(swatch.color), selected: lip?.color == swatch.color,
                             apply: { face in edit(&face) { $0.color = swatch.color } })
            }
        case 2:
            return MKLipTexture.allCases.map { texture in
                MakeupOption(id: "t\(texture.rawValue)", title: texture.title, selected: lip?.texture == texture,
                             apply: { face in edit(&face) { $0.texture = texture } },
                             preview: { $0.lip = LipMakeup(color: MakeupCatalog.lipColor("斩男色"), texture: texture) })
            }
        case 3:
            return MKLipStyle.allCases.map { style in
                MakeupOption(id: "s\(style.rawValue)", title: style.title, selected: lip?.style == style,
                             apply: { face in edit(&face) { $0.style = style } },
                             preview: { $0.lip = LipMakeup(color: MakeupCatalog.lipColor("斩男色"), style: style) })
            }
        default:
            let levels: [(String, CGFloat)] = [("无", 0), ("自然", 0.5), ("明显", 1)]
            return levels.map { name, value in
                MakeupOption(id: "l\(name)", title: name, selected: lip != nil && abs((lip?.liner ?? 0) - value) < 0.02,
                             apply: { face in edit(&face) { $0.liner = value } },
                             preview: { $0.lip = LipMakeup(color: MakeupCatalog.lipColor("复古红"), texture: .matte, liner: value) })
            }
        }
    }

    // MARK: 眉毛

    private func browOptions(_ state: MakeupState, _ m: FaceMakeup?) -> [MakeupOption] {
        let brow = m?.brow
        if state.tab == 1 {
            return MakeupCatalog.browColors.map { swatch in
                MakeupOption(id: swatch.name, title: swatch.name, kind: .swatch(swatch.color), selected: brow?.color == swatch.color,
                             apply: { face in
                                 if face.brow == nil { face.brow = MakeupCatalog.browPreset(.natural) }
                                 face.brow?.color = swatch.color
                             })
            }
        }
        var list = [none(selected: brow == nil) { $0.brow = nil }]
        for shape in MKBrowShape.allCases {
            list.append(MakeupOption(id: "b\(shape.rawValue)", title: shape.title, selected: brow?.shape == shape,
                                     apply: { face in
                                         var value = MakeupCatalog.browPreset(shape)
                                         // 已经挑过颜色、调过浓淡的话，换眉形时保留。
                                         if let old = face.brow { value.color = old.color; value.amount = old.amount }
                                         face.brow = value
                                     },
                                     preview: { $0.brow = MakeupCatalog.browPreset(shape); $0.brow?.amount = 0.75 }))
        }
        return list
    }

    // MARK: 眼妆

    private func eyeOptions(_ state: MakeupState, _ m: FaceMakeup?) -> [MakeupOption] {
        let eye = m?.eye ?? EyeMakeup()
        switch state.tab {
        case 0:
            var list = [none(selected: eye.isEmpty, slot: "eye") { $0.eye = EyeMakeup() }]
            for preset in MakeupCatalog.eyePresets {
                list.append(MakeupOption(id: preset.name, title: preset.name, selected: !eye.isEmpty && state.pick("eye") == preset.name,
                                         apply: { $0.eye = preset.eye }, preview: { $0.eye = preset.eye }, slot: "eye"))
            }
            return list
        case 1:
            var list = [none("无", selected: eye.shadow == nil) { $0.eye.shadow = nil }]
            for preset in MakeupCatalog.shadows {
                let on = eye.shadow.map { $0.lid == preset.shadow.lid && $0.crease == preset.shadow.crease && $0.outer == preset.shadow.outer } ?? false
                list.append(MakeupOption(id: preset.name, title: preset.name, selected: on,
                                         apply: { face in
                                             var value = preset.shadow
                                             if let old = face.eye.shadow { value.amount = old.amount }
                                             face.eye.shadow = value
                                         },
                                         preview: { $0.eye.shadow = preset.shadow; $0.eye.shadow?.amount = 0.85 }))
            }
            return list
        case 2:
            var list = [none("无", selected: eye.liner == nil) { $0.eye.liner = nil }]
            for style in MKLinerStyle.allCases {
                list.append(MakeupOption(id: "l\(style.rawValue)", title: style.title, selected: eye.liner?.style == style,
                                         apply: { face in
                                             var value = face.eye.liner ?? LinerMakeup(style: style)
                                             value.style = style
                                             face.eye.liner = value
                                         },
                                         preview: { $0.eye.liner = LinerMakeup(style: style) }))
            }
            for swatch in MakeupCatalog.linerColors {
                list.append(MakeupOption(id: "c" + swatch.name, title: swatch.name, kind: .swatch(swatch.color),
                                         selected: eye.liner?.color == swatch.color,
                                         apply: { face in
                                             var value = face.eye.liner ?? LinerMakeup(style: .natural)
                                             value.color = swatch.color
                                             face.eye.liner = value
                                         }))
            }
            return list
        case 3:
            var list = [none("无", selected: eye.lashes == nil) { $0.eye.lashes = nil }]
            for style in MKLashStyle.allCases {
                list.append(MakeupOption(id: "h\(style.rawValue)", title: style.title, selected: eye.lashes?.style == style,
                                         apply: { face in
                                             var value = face.eye.lashes ?? LashMakeup(style: style)
                                             value.style = style
                                             face.eye.lashes = value
                                         },
                                         preview: { $0.eye.lashes = LashMakeup(style: style, amount: 1) }))
            }
            return list
        case 4:
            let levels: [(String, CGFloat)] = [("无", 0), ("自然", 0.5), ("明显", 0.9)]
            return levels.map { name, value in
                MakeupOption(id: "a\(name)", title: name, selected: abs(eye.aegyo - value) < 0.02,
                             apply: { $0.eye.aegyo = value }, preview: { $0.eye.aegyo = value })
            }
        case 5:
            var list = [none("无", selected: eye.lens == nil) { $0.eye.lens = nil }]
            for swatch in MakeupCatalog.lensColors {
                list.append(MakeupOption(id: swatch.name, title: swatch.name, selected: eye.lens?.color == swatch.color,
                                         apply: { face in
                                             var value = face.eye.lens ?? LensMakeup(color: swatch.color)
                                             value.color = swatch.color
                                             face.eye.lens = value
                                         },
                                         preview: { $0.eye.lens = LensMakeup(color: swatch.color, amount: 0.75) }))
            }
            return list
        case 6:
            var list = [none("无", selected: eye.foldAmount <= 0) { $0.eye.foldAmount = 0 }]
            for style in MKFoldStyle.allCases {
                list.append(MakeupOption(id: "f\(style.rawValue)", title: style.title, selected: eye.foldAmount > 0 && eye.fold == style,
                                         apply: { face in
                                             face.eye.fold = style
                                             if face.eye.foldAmount <= 0 { face.eye.foldAmount = 0.7 }
                                         },
                                         preview: { $0.eye.fold = style; $0.eye.foldAmount = 1 }))
            }
            return list
        default:
            var list = [none("无", selected: eye.catchlightAmount <= 0) { $0.eye.catchlightAmount = 0 }]
            for style in MKCatchlight.allCases {
                list.append(MakeupOption(id: "g\(style.rawValue)", title: style.title,
                                         selected: eye.catchlightAmount > 0 && eye.catchlight == style,
                                         apply: { face in
                                             face.eye.catchlight = style
                                             if face.eye.catchlightAmount <= 0 { face.eye.catchlightAmount = 0.75 }
                                         },
                                         preview: { $0.eye.catchlight = style; $0.eye.catchlightAmount = 1 }))
            }
            return list
        }
    }

    // MARK: 修容

    private func contourOptions(_ state: MakeupState, _ m: FaceMakeup?) -> [MakeupOption] {
        let c = m?.contour ?? ContourMakeup()
        switch state.tab {
        case 0:
            var list = [none(selected: c.sculptIsEmpty, slot: "sculpt") { $0.contour.setSculpt(ContourMakeup()) }]
            for preset in MakeupCatalog.contourPresets {
                list.append(MakeupOption(id: preset.name, title: preset.name,
                                         selected: !c.sculptIsEmpty && state.pick("sculpt") == preset.name,
                                         apply: { $0.contour.setSculpt(preset.contour) },
                                         preview: { $0.contour.setSculpt(preset.contour); $0.contour.scaleSculpt(by: 1.25) },
                                         slot: "sculpt"))
            }
            return list
        case 1, 2:
            let zones: [(String, String)] = state.tab == 1
                ? [("forehead", "额头"), ("noseLight", "鼻梁"), ("cheekLight", "颧骨"), ("chinLight", "下巴"), ("cupid", "唇峰"), ("underEye", "眼下")]
                : [("noseShade", "鼻影"), ("jaw", "下颌"), ("cheekShade", "颧下"), ("temple", "额角")]
            let ids = zones.map(\.0)
            var list = [none("无", selected: ids.allSatisfy { Self.zoneValue($0, c) <= 0 }) { face in
                for id in ids { Self.setZone(id, 0, &face.contour) }
            }]
            for (id, name) in zones {
                let value = Self.zoneValue(id, c)
                list.append(MakeupOption(id: id, title: value > 0 ? name + " ✓" : name, selected: state.zone == id,
                                         apply: { face in
                                             // 第一次点是打开这一区；已经开着的话只是选中它，用滑块调。
                                             if Self.zoneValue(id, face.contour) <= 0 { Self.setZone(id, 0.7, &face.contour) }
                                         },
                                         preview: { Self.setZone(id, 1, &$0.contour) }, zone: id))
            }
            return list
        case 3:
            var list = [none("无", selected: c.freckleAmount <= 0) { $0.contour.freckleAmount = 0 }]
            for style in MKFreckleStyle.allCases {
                list.append(MakeupOption(id: "k\(style.rawValue)", title: style.title, selected: c.freckleAmount > 0 && c.freckles == style,
                                         apply: { face in
                                             face.contour.freckles = style
                                             if face.contour.freckleAmount <= 0 { face.contour.freckleAmount = 0.6 }
                                         },
                                         preview: { $0.contour.freckles = style; $0.contour.freckleAmount = 1 }))
            }
            return list
        default:
            var list = [none("无", selected: c.moles.isEmpty) { $0.contour.moles = [] }]
            for spot in MKMoleSpot.presets {
                let on = c.moles.contains(spot)
                list.append(MakeupOption(id: "m" + spot.title, title: spot.title, selected: on,
                                         apply: { face in
                                             if let index = face.contour.moles.firstIndex(of: spot) {
                                                 face.contour.moles.remove(at: index)
                                             } else {
                                                 face.contour.moles.append(spot)
                                             }
                                         },
                                         preview: { $0.contour.moles = [spot] }))
            }
            list.append(MakeupOption(id: "place", title: "自己点", kind: .symbol("hand.tap"), selected: state.placingMole,
                                     togglesMolePlacing: true))
            return list
        }
    }

    // MARK: 腮红

    private func blushOptions(_ state: MakeupState, _ m: FaceMakeup?) -> [MakeupOption] {
        let blush = m?.blush
        let fallback = MakeupCatalog.blushColor("蜜桃")
        func edit(_ face: inout FaceMakeup, _ change: (inout BlushMakeup) -> Void) {
            var value = face.blush ?? BlushMakeup(color: fallback)
            if value.amount <= 0 { value.amount = 0.55 }
            change(&value)
            face.blush = value
        }
        switch state.tab {
        case 0:
            var list = [none(selected: blush == nil, slot: "blush") { $0.blush = nil }]
            for preset in MakeupCatalog.blushPresets {
                list.append(MakeupOption(id: preset.name, title: preset.name, selected: blush != nil && state.pick("blush") == preset.name,
                                         apply: { $0.blush = preset.blush },
                                         preview: { $0.blush = preset.blush; $0.blush?.amount = min(1, preset.blush.amount * 1.3) },
                                         slot: "blush"))
            }
            return list
        case 1:
            return MakeupCatalog.blushColors.map { swatch in
                MakeupOption(id: swatch.name, title: swatch.name, kind: .swatch(swatch.color), selected: blush?.color == swatch.color,
                             apply: { face in edit(&face) { $0.color = swatch.color } })
            }
        case 2:
            return MKBlushPlacement.allCases.map { placement in
                MakeupOption(id: "p\(placement.rawValue)", title: placement.title, selected: blush?.placement == placement,
                             apply: { face in edit(&face) { $0.placement = placement } },
                             preview: { $0.blush = BlushMakeup(color: MakeupCatalog.blushColor("玫瑰"), placement: placement, amount: 0.8) })
            }
        default:
            return [false, true].map { glow in
                MakeupOption(id: glow ? "glow" : "matte", title: glow ? "光泽" : "哑光", selected: blush != nil && blush?.glow == glow,
                             apply: { face in edit(&face) { $0.glow = glow } },
                             preview: { $0.blush = BlushMakeup(color: MakeupCatalog.blushColor("樱花粉"), glow: glow, amount: 0.8) })
            }
        }
    }
}

/// 没法只靠五官位置画出来的那些：美甲、酒窝、饰品、纹身贴，交给 AI。
enum MakeupAI {
    private static func nail(_ title: String, _ style: String) -> AIPreset {
        AIPreset(title: title, symbol: "hand.raised.fingers.spread",
                 prompt: "给画面里露出来的每一个指甲做美甲：\(style)。只改指甲表面的颜色和图案；指甲的形状和长度、手的姿势和位置、肤色，以及画面里其他所有东西都保持不变。画面里看不到指甲就什么都不要改。")
    }

    static let nails: [AIPreset] = [
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
    ]

    private static func face(_ title: String, _ symbol: String, _ what: String) -> AIPreset {
        AIPreset(title: title, symbol: symbol,
                 prompt: "\(what)。只加这一样，五官的形状和位置、表情、妆容、肤色、发型和其他所有东西都保持不变，必须还是同一个人，看起来像照片里本来就有的。",
                 faceCrop: true)
    }

    static let face: [AIPreset] = [
        face("小酒窝", "face.smiling", "在两边脸颊各加一个自然的小酒窝"),
        face("梨涡", "mouth", "在两边嘴角外侧各加一个小小的梨涡"),
        face("鼻钉", "circle.fill", "在一侧鼻翼上加一颗很小的银色鼻钉"),
        face("眉尾钉", "diamond", "在一侧眉尾加一枚小巧的银色眉钉"),
        face("唇钉", "circle.fill", "在下唇一侧加一枚小小的银色唇钉"),
        face("泪钻", "sparkle", "在两只眼睛的下眼角各贴两三颗细小的水钻"),
        face("脸颊爱心", "heart", "在一侧颧骨上贴一颗很小的红色爱心面贴"),
        face("星星面贴", "star.fill", "在一侧眼尾下方贴两三颗很小的银色星星面贴"),
    ]

    private static func tattoo(_ title: String, _ symbol: String, _ what: String) -> AIPreset {
        AIPreset(title: title, symbol: symbol,
                 prompt: "\(what)，像一枚贴上去的纹身贴：线条细致，顺着皮肤的起伏和明暗，被衣服或头发挡住的地方不要画出来。那个部位在画面里看不到就什么都不要改。人物的长相、姿势、服装和画面里其他所有东西都保持不变。")
    }

    static let tattoo: [AIPreset] = [
        tattoo("锁骨蝴蝶", "leaf", "在一侧锁骨下方加一只小小的黑色线条蝴蝶"),
        tattoo("锁骨英文", "textformat", "沿着一侧锁骨加一行纤细的黑色手写英文花体字"),
        tattoo("手臂玫瑰", "camera.macro", "在一只上臂外侧加一朵黑色线条的玫瑰"),
        tattoo("颈侧星月", "moon.stars", "在脖子侧面加一个很小的月亮和两三颗星星"),
        tattoo("手腕小花", "camera.macro", "在一只手腕内侧加一朵很小的线条小花"),
        tattoo("肩头藤蔓", "leaf", "在一侧肩头加一小段纤细的藤蔓叶子"),
    ]
}
