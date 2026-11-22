import Foundation

/// 男士用的那一套：一键美颜、AI 美体、发型、染发、发质发量、一键美体、妆容。
enum MalePresets {
    private static let keepHair = "脸、五官、表情、肤色、衣服、姿势和背景都不变，必须还是同一个人。"

    private static func style(_ title: String, _ desc: String) -> AIPreset {
        AIPreset(title: title, symbol: "scissors",
                 prompt: "把发型换成\(desc)。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。" + keepHair, hairCrop: true)
    }

    private static func color(_ title: String, _ desc: String, _ tint: UInt32) -> AIPreset {
        AIPreset(title: title, symbol: "paintpalette",
                 prompt: "把头发染成\(desc)。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。" + keepHair,
                 hairCrop: true, tint: tint)
    }

    private static func care(_ title: String, _ symbol: String, _ desc: String) -> AIPreset {
        AIPreset(title: title, symbol: symbol, prompt: desc + keepHair, hairCrop: true)
    }

    // MARK: 发型

    static let hairStyles: [AIPreset] = [
        style("寸头", "干净利落的男士寸头"),
        style("板寸", "头顶平整、四周短的男士板寸"),
        style("渐变寸", "两侧和后脑由短到长渐变推短（fade）、头顶稍长的男士短发"),
        style("背头", "向后梳的男士背头"),
        style("油头", "有光泽、侧分后梳的男士复古油头，两侧推短"),
        style("纹理烫", "蓬松有层次的男士纹理烫"),
        style("微分碎盖", "韩式微分碎盖男士短发"),
        style("韩式中分", "韩式中分男士发型，刘海自然垂在两侧"),
        style("日系碎发", "日系蓬松碎发男士短发，发尾有轻微的动感"),
        style("锡纸烫", "卷度明显、立体蓬松的男士锡纸烫"),
        style("飞机头", "前额头发向上向后吹起、很有精神的男士飞机头"),
        style("狼尾", "后颈留长的狼尾发型"),
        style("莫西干", "两侧剃短、中间一道竖起的莫西干发型"),
        style("半扎发", "到肩的男士中长发，上半部分在脑后扎成小揪"),
        style("自然卷", "蓬松自然的男士短卷发"),
        style("刘海碎发", "带齐眉碎刘海的男士短发"),
    ]

    /// 发型示意图：新加的男士发型借用最像的那一张。
    static let hairArtAlias: [String: String] = [
        "板寸": "寸头", "渐变寸": "寸头", "油头": "背头", "飞机头": "背头", "莫西干": "寸头",
        "韩式中分": "微分碎盖", "日系碎发": "微分碎盖", "刘海碎发": "微分碎盖",
        "锡纸烫": "纹理烫", "自然卷": "纹理烫", "半扎发": "狼尾",
    ]

    // MARK: 染发

    static let hairColors: [AIPreset] = [
        color("自然黑", "自然的黑色", 0x1A1A1C),
        color("深棕", "深棕色", 0x3B2A20),
        color("冷棕", "偏冷的灰棕色", 0x5A4A42),
        color("亚麻灰", "亚麻灰色", 0x8C8478),
        color("奶奶灰", "浅浅的奶奶灰色", 0xB9B6B0),
        color("银灰", "银灰色", 0xA9ADB3),
        color("雾霾蓝", "低饱和的雾霾蓝色", 0x6F8FA6),
        color("深蓝黑", "带一点蓝调的蓝黑色", 0x1C2433),
        color("金色", "明亮的金色", 0xD9B56A),
        color("白金", "很浅的白金色", 0xE9E1CF),
        color("酒红", "深酒红色", 0x6E1F2B),
        AIPreset(title: "挑染", symbol: "paintbrush.pointed",
                 prompt: "在现有发色上加几缕浅色的挑染，层次自然，发型不变。" + keepHair, hairCrop: true),
    ]

    // MARK: 发质发量、胡子

    static let hairCare: [AIPreset] = [
        care("蓬松", "cloud", "让头发更蓬松有型，发根立起来，发型的样式和发色不变。"),
        care("增加发量", "plus.circle", "让头发更浓密、发量更多，看起来自然，发型的样式和发色不变。"),
        care("高颅顶", "arrow.up.circle", "让头顶的头发更蓬、颅顶更高更饱满，发型的样式和发色不变。"),
        care("填充发际线", "person.crop.circle", "把稀疏、后移的发际线和 M 型发际线补得自然饱满，新长出的头发和原来的发色、发质一致。"),
        care("AI 生发", "leaf", "让头顶、发缝和稀疏的地方长出自然的头发，遮住露出的头皮，新头发和原来的发色、发质一致。"),
        care("遮盖白发", "moon", "把白发和灰发染回和周围头发一样的颜色，发型不变。"),
        care("修鬓角", "scissors", "把鬓角和耳朵周围的头发修整齐、干净利落，发型的样式和发色不变。"),
        care("去胡茬", "sparkle", "把脸上和下巴的胡茬刮干净，皮肤自然，不要变得光滑塑料。"),
        care("修整胡型", "mustache", "把胡子修整齐：边缘清楚、长短一致，保持原来的胡型。"),
        care("加胡子", "mustache.fill", "加上自然好看的短胡子（嘴唇上方和下巴一圈的短须），颜色和发色一致，像真的长出来的。"),
    ]

    // MARK: AI 美体

    private static let keepBody = "人物长相、发型、姿势、服装的款式和颜色、背景都不变，结果仍然是一张真实的照片。"

    static let body: [AIPreset] = [
        AIPreset(title: "精壮", symbol: "figure.strengthtraining.traditional",
                 prompt: "让身材更精壮：肩膀、手臂和胸部有健康的肌肉线条，腰腹紧实，不要夸张。" + keepBody),
        AIPreset(title: "腹肌", symbol: "figure.core.training", prompt: "让腹部平坦紧实，有自然的腹肌轮廓，不要夸张。" + keepBody),
        AIPreset(title: "宽肩", symbol: "arrow.left.and.right", prompt: "让肩膀稍微宽一些、更挺拔，比例自然。" + keepBody),
        AIPreset(title: "手臂线条", symbol: "figure.arms.open", prompt: "让手臂的肌肉线条更清楚一些，粗细自然。" + keepBody),
        AIPreset(title: "收腹", symbol: "arrow.right.and.line.vertical.and.arrow.left", prompt: "去掉小肚腩，让腰腹更平坦，保持自然。" + keepBody),
        AIPreset(title: "长腿", symbol: "figure.walk", prompt: "把腿稍微拉长一些，让身材比例更修长，背景不要变形。" + keepBody),
        AIPreset(title: "挺拔", symbol: "figure.stand", prompt: "让体态更挺拔：背部挺直、肩膀打开、头部回到肩膀正上方。" + keepBody),
    ]

    /// 一键美体（塑形工具）里的 AI 预设。
    static let shapeLooks: [AIPreset] = [
        AIPreset(title: "精壮", symbol: "figure.strengthtraining.traditional",
                 prompt: "让身材更精壮：肩膀、胸、手臂有健康的肌肉线条，腰腹紧实，不要夸张。" + keepBody),
        AIPreset(title: "宽肩窄腰", symbol: "figure.stand",
                 prompt: "让肩膀更宽、腰更窄，呈现倒三角的身材比例，不要夸张。" + keepBody),
        AIPreset(title: "精瘦", symbol: "figure.cooldown",
                 prompt: "让全身更精瘦干练：去掉多余的赘肉，线条紧实，体型大小基本不变。" + keepBody),
        AIPreset(title: "增肌", symbol: "figure.strengthtraining.functional",
                 prompt: "让肌肉明显更多一些：手臂、肩膀、胸和腹部都更有块头和轮廓，像常健身的人，不要夸张。" + keepBody),
    ]

    // MARK: 一键美颜

    static let beautyStyles: [BeautyStyle] = [
        BeautyStyle(title: "自然", prompt: "natural men's grooming retouch. Even out skin tone, remove blemishes and acne marks, reduce dark circles and oily shine. Keep masculine skin texture, pores and any facial hair. No makeup look."),
        BeautyStyle(title: "清爽", prompt: "clean fresh look for a man. Clear matte skin without oiliness, tidier brows, brighter eyes, healthy natural complexion. No visible makeup."),
        BeautyStyle(title: "精神", prompt: "energetic awake look for a man. Remove tiredness, dark circles and eye bags, brighten the eyes, healthy color in the face, firmer skin."),
        BeautyStyle(title: "硬朗", prompt: "rugged masculine look. Stronger defined jawline and cheekbones through light and shadow, thicker straighter brows, slightly deeper-set eyes. Keep skin texture and stubble."),
        BeautyStyle(title: "轮廓", prompt: "sharper facial contour for a man. Slimmer cleaner jawline and chin, less double chin and puffiness, defined nose bridge. Still masculine and the same person."),
        BeautyStyle(title: "韩系男团", prompt: "Korean male idol look. Clear luminous skin, neat straight brows, bright clear eyes, subtle natural lip color, soft refined features. Very natural, no visible makeup."),
        BeautyStyle(title: "少年感", prompt: "youthful boyish look. Smoother fresher skin, brighter eyes, softer under-eyes, a bit fuller cheeks. Still clearly the same adult man."),
        BeautyStyle(title: "成熟", prompt: "mature charismatic look for a man. Refined skin with texture, defined brows and jaw, calm confident eyes, subtle depth in the features."),
        BeautyStyle(title: "去油", prompt: "oil control. Remove oily shine on forehead, nose and cheeks, matte healthy skin, keep texture and pores."),
        BeautyStyle(title: "补光", prompt: "flattering light for a man. Add soft frontal fill light on the face, brighten it evenly, catchlights in the eyes, reduce harsh shadows, keep masculine structure."),
    ]
}

extension MakeupCatalog {
    /// 男士妆容：以修饰为主，看不出化了妆。
    static let maleLooks: [LookPreset] = {
        func lip(_ amount: CGFloat, _ color: String = "裸粉") -> LipMakeup {
            LipMakeup(color: lipColor(color), amount: amount, texture: .satin)
        }
        var plain = LookPreset(name: "男士素颜")
        plain.brow = browPreset(.natural); plain.brow?.amount = 0.3
        plain.lip = lip(0.2)
        plain.contour.underEye = 0.35
        plain.contour.noseLight = 0.15

        var fresh = LookPreset(name: "清爽少年")
        fresh.brow = browPreset(.straight); fresh.brow?.amount = 0.4
        fresh.lip = lip(0.3)
        fresh.contour.forehead = 0.2; fresh.contour.noseLight = 0.25; fresh.contour.underEye = 0.3

        var rugged = LookPreset(name: "硬朗轮廓")
        rugged.brow = browPreset(.sword); rugged.brow?.amount = 0.55
        rugged.lip = lip(0.15)
        rugged.contour.jaw = 0.5; rugged.contour.cheekShade = 0.45; rugged.contour.noseShade = 0.4; rugged.contour.noseLight = 0.3

        var idol = LookPreset(name: "精致男团")
        idol.brow = browPreset(.straight); idol.brow?.amount = 0.5
        idol.lip = lip(0.35, "奶茶")
        idol.contour.noseShade = 0.3; idol.contour.cheekLight = 0.2; idol.contour.underEye = 0.3

        var wild = LookPreset(name: "野生眉")
        wild.brow = browPreset(.wild); wild.brow?.amount = 0.55
        wild.lip = lip(0.2)

        var healthy = LookPreset(name: "好气色")
        healthy.brow = browPreset(.natural); healthy.brow?.amount = 0.35
        healthy.lip = lip(0.4, "豆沙")
        healthy.blush = blushPreset("奶杏", amount: 0.18)
        healthy.contour.underEye = 0.3

        return [plain, fresh, rugged, idol, wild, healthy]
    }()

    /// 按女 / 男开关列出来的妆容。
    static var currentLooks: [LookPreset] { GenderSetting.shared.isMale ? maleLooks : looks }
}

extension BeautyStyle {
    /// 按女 / 男开关列出来的一键美颜风格。
    static var current: [BeautyStyle] { GenderSetting.shared.isMale ? MalePresets.beautyStyles : all }

    /// 按名字找风格（男女两套都找）。
    static func named(_ id: String?) -> BeautyStyle? {
        guard let id else { return nil }
        let list = GenderSetting.shared.isMale ? MalePresets.beautyStyles + all : all + MalePresets.beautyStyles
        return list.first { $0.id == id }
    }
}
