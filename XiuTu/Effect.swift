import CoreImage

/// 特效的分类。
enum EffectCategory: String, CaseIterable, Identifiable {
    case light, blur, retro, atmosphere, sky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "光"
        case .blur: return "模糊"
        case .retro: return "复古"
        case .atmosphere: return "氛围"
        case .sky: return "换天"
        }
    }
}

/// 一个效果的变体（颜色、方向等）。
struct EffectVariant: Hashable {
    let title: String
    /// 主色（线性之前的 sRGB 0…1）。
    var r: CGFloat = 1
    var g: CGFloat = 1
    var b: CGFloat = 1
}

/// 本机特效。
enum EffectKind: String, CaseIterable, Identifiable {
    // 光
    case blackMist, whiteMist, softFocus, rimLight, sunFlare, starburst, godRays, lightLeak, rainbow, bokehLight, leafShadow, blinds
    // 模糊
    case bgBlur, bokeh, defocus, motionBlur, zoomBlur, ghost, longExposure, gaussian
    // 复古
    case vhs, lowPixel, led, neon, glitch, crt, vaporwave, halftone, lofi
    // 氛围
    case goldGlitter, twinkle, snow, colorSnow, petals, leaves, confetti, hearts, bubbles, fireflies, rain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blackMist: return "黑柔"
        case .whiteMist: return "白柔"
        case .softFocus: return "柔焦"
        case .rimLight: return "轮廓光"
        case .sunFlare: return "逆光光晕"
        case .starburst: return "星芒"
        case .godRays: return "丁达尔光"
        case .lightLeak: return "漏光"
        case .rainbow: return "彩虹光"
        case .bokehLight: return "光斑"
        case .leafShadow: return "树影"
        case .blinds: return "百叶窗"
        case .bgBlur: return "背景虚化"
        case .bokeh: return "焦外光斑"
        case .defocus: return "失焦"
        case .motionBlur: return "动态模糊"
        case .zoomBlur: return "放射模糊"
        case .ghost: return "拖影"
        case .longExposure: return "长曝光"
        case .gaussian: return "高斯模糊"
        case .vhs: return "录像带"
        case .lowPixel: return "低像素"
        case .led: return "电子屏"
        case .neon: return "霓虹描边"
        case .glitch: return "故障"
        case .crt: return "老电视"
        case .vaporwave: return "蒸汽波"
        case .halftone: return "半调网点"
        case .lofi: return "低保真"
        case .goldGlitter: return "金粉闪光"
        case .twinkle: return "星星闪光"
        case .snow: return "雪花"
        case .colorSnow: return "彩色雪花"
        case .petals: return "樱花飘落"
        case .leaves: return "落叶"
        case .confetti: return "礼花彩带"
        case .hearts: return "爱心"
        case .bubbles: return "气泡"
        case .fireflies: return "萤火"
        case .rain: return "雨丝"
        }
    }

    var category: EffectCategory {
        switch self {
        case .blackMist, .whiteMist, .softFocus, .rimLight, .sunFlare, .starburst, .godRays, .lightLeak, .rainbow,
             .bokehLight, .leafShadow, .blinds:
            return .light
        case .bgBlur, .bokeh, .defocus, .motionBlur, .zoomBlur, .ghost, .longExposure, .gaussian:
            return .blur
        case .vhs, .lowPixel, .led, .neon, .glitch, .crt, .vaporwave, .halftone, .lofi:
            return .retro
        default:
            return .atmosphere
        }
    }

    /// 没有主体蒙版就做不了。
    var needsMask: Bool { self == .rimLight || self == .bgBlur || self == .bokeh }

    /// 有主体蒙版时会用上（主体保持清晰），没有也能做。
    var usesMask: Bool { needsMask || self == .motionBlur || self == .zoomBlur || self == .ghost || self == .longExposure }

    /// 位置是随机的，可以"换一换"。
    var shuffles: Bool {
        category == .atmosphere || self == .glitch || self == .bokehLight || self == .leafShadow || self == .godRays
            || self == .rainbow || self == .starburst
    }

    var defaultStrength: CGFloat {
        switch self {
        case .rimLight: return 0.8
        case .gaussian, .defocus: return 0.5
        default: return 0.7
        }
    }

    var variants: [EffectVariant] {
        switch self {
        case .rimLight:
            return [
                EffectVariant(title: "白", r: 1, g: 1, b: 1),
                EffectVariant(title: "暖", r: 1, g: 0.72, b: 0.38),
                EffectVariant(title: "冷", r: 0.55, g: 0.78, b: 1),
                EffectVariant(title: "粉", r: 1, g: 0.55, b: 0.78),
                EffectVariant(title: "紫", r: 0.72, g: 0.5, b: 1),
            ]
        case .sunFlare:
            return [EffectVariant(title: "暖阳", r: 1, g: 0.78, b: 0.48), EffectVariant(title: "白光", r: 1, g: 0.97, b: 0.92)]
        case .starburst:
            return [EffectVariant(title: "四芒"), EffectVariant(title: "六芒"), EffectVariant(title: "八芒")]
        case .godRays:
            return [EffectVariant(title: "左上", r: 1, g: 0.86, b: 0.6), EffectVariant(title: "右上", r: 1, g: 0.86, b: 0.6)]
        case .lightLeak:
            return [
                EffectVariant(title: "暖橙", r: 1, g: 0.45, b: 0.12),
                EffectVariant(title: "玫红", r: 1, g: 0.2, b: 0.35),
                EffectVariant(title: "蓝紫", r: 0.45, g: 0.3, b: 1),
                EffectVariant(title: "青绿", r: 0.15, g: 0.85, b: 0.7),
            ]
        case .bokehLight:
            return [
                EffectVariant(title: "暖", r: 1, g: 0.78, b: 0.45),
                EffectVariant(title: "冷", r: 0.6, g: 0.8, b: 1),
                EffectVariant(title: "彩"),
            ]
        case .neon:
            return [
                EffectVariant(title: "粉", r: 1, g: 0.25, b: 0.75),
                EffectVariant(title: "青", r: 0.2, g: 0.95, b: 1),
                EffectVariant(title: "紫", r: 0.65, g: 0.35, b: 1),
                EffectVariant(title: "绿", r: 0.35, g: 1, b: 0.45),
            ]
        case .motionBlur:
            return [EffectVariant(title: "横向"), EffectVariant(title: "竖向")]
        default:
            return []
        }
    }

    static func by(_ id: String) -> EffectKind? { EffectKind(rawValue: id) }

    static func list(_ category: EffectCategory) -> [EffectKind] { allCases.filter { $0.category == category } }
}

/// 一步特效。参数全是相对值，预览和原图一样；随机的东西由 seed 决定。
struct EffectParams: Equatable, Codable {
    /// 存配方时不存蒙版：套用到新照片时按新照片重新算。
    private enum CodingKeys: String, CodingKey { case id, strength, variant, seed, chaos }

    var id = ""
    var strength: CGFloat = 0.7
    var variant = 0
    var seed: UInt64 = 7
    /// 随机度 0.01...1：粒子、光斑、光束的大小、亮度、角度差别有多大。0.5 = 默认。
    var chaos: CGFloat = 0.5
    /// 主体蒙版（白 = 主体），在进工具时对当时的画面算好。
    var mask: CGImage?

    var kind: EffectKind? { EffectKind.by(id) }

    var isIdentity: Bool {
        guard let kind, strength > 0.001 else { return true }
        return kind.needsMask && mask == nil
    }

    static func == (a: EffectParams, b: EffectParams) -> Bool {
        a.id == b.id && a.strength == b.strength && a.variant == b.variant && a.seed == b.seed && a.chaos == b.chaos && a.mask === b.mask
    }

    func apply(to image: CIImage) -> CIImage {
        guard !isIdentity, let kind else { return image }
        let e = image.extent
        guard !e.isInfinite, e.width >= 2, e.height >= 2 else { return image }
        // 统一挪到原点算，算完挪回去。
        let moved = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let maskCI = mask.map { Cutout.scaled($0, to: moved.extent) }
        let variants = kind.variants
        let v = variants.isEmpty ? EffectVariant(title: "") : variants[min(max(variant, 0), variants.count - 1)]
        let out = EffectRender.render(kind, image: moved, strength: min(max(strength, 0), 1), variant: v,
                                      variantIndex: variant, seed: seed, chaos: chaos, mask: maskCI)
        return out.cropped(to: moved.extent).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    }
}

/// 换天：交给 AI。
struct EffectSky: Identifiable {
    let title: String
    let symbol: String
    /// 缩略图的渐变色（上 → 下），0xRRGGBB。
    let colors: [UInt32]
    let sky: String

    var id: String { title }

    var preset: AIPreset {
        AIPreset(title: title, symbol: symbol, prompt: """
        把这张照片里的天空换成\(sky)。只替换天空部分：人物、建筑、树木、地面、水面和整个构图一律保持原样，\
        位置、大小和轮廓都不能变，不要裁剪、不要改变画面比例，结果要和原图对齐。\
        让画面整体的光线方向、明暗和色调与新的天空协调（地面、建筑和人物身上带上相应的环境光和反光），\
        但人物的长相、表情和衣服不变。要真实自然，像实拍的，不要有抠图合成感。
        """)
    }

    static let all: [EffectSky] = [
        EffectSky(title: "晴朗蓝天", symbol: "sun.max.fill", colors: [0x2F7BE0, 0x8EC5F5, 0xE6F3FF],
                  sky: "晴朗通透的蓝天，飘着几朵自然的白云"),
        EffectSky(title: "晚霞", symbol: "cloud.sun.fill", colors: [0x5B4A9E, 0xE0729A, 0xFFB37A],
                  sky: "绚丽的晚霞，粉紫和橙色的云层铺满天空"),
        EffectSky(title: "夕阳", symbol: "sunset.fill", colors: [0xC2462C, 0xF08A3C, 0xFFD27A],
                  sky: "金色的夕阳天空，太阳低垂在地平线附近，暖橙色的光"),
        EffectSky(title: "星空", symbol: "sparkles", colors: [0x070B24, 0x1B2552, 0x3A3F7A],
                  sky: "清澈的夜晚星空，满天繁星，深蓝色的夜空（画面整体变成夜景）"),
        EffectSky(title: "银河", symbol: "moon.stars.fill", colors: [0x05071A, 0x2A2160, 0x8A6BB8],
                  sky: "璀璨的银河横跨夜空，星星密布（画面整体变成夜景）"),
        EffectSky(title: "超级月亮", symbol: "moon.fill", colors: [0x0C1530, 0x2A3A66, 0xC9CFE0],
                  sky: "夜空中一轮又大又亮的满月，月面细节清晰（画面整体变成夜景）"),
        EffectSky(title: "血月", symbol: "moon.circle.fill", colors: [0x12060A, 0x4A0E14, 0xB02A22],
                  sky: "夜空中一轮巨大的暗红色血月（画面整体变成夜景）"),
        EffectSky(title: "极光", symbol: "wind", colors: [0x061A2A, 0x0F6B5C, 0x6CF2B0],
                  sky: "夜空中舞动的绿色和紫色极光（画面整体变成夜景）"),
        EffectSky(title: "烟花", symbol: "sparkle", colors: [0x0A0A1E, 0x3A1A4A, 0xF2A33A],
                  sky: "夜空中绽放的大片绚丽烟花（画面整体变成夜景）"),
        EffectSky(title: "彩虹", symbol: "rainbow", colors: [0x6AA8E8, 0xA8D4F2, 0xF4E9C8],
                  sky: "雨后放晴的天空，挂着一道清晰的彩虹"),
        EffectSky(title: "雪夜", symbol: "snowflake", colors: [0x1A2438, 0x4A5A78, 0xD8E2F0],
                  sky: "飘着雪的冬夜天空，空中有自然飘落的雪花（画面整体变成雪夜）"),
        EffectSky(title: "粉色梦幻云", symbol: "cloud.fill", colors: [0xF6A6C8, 0xFBD3E0, 0xC9D6FF],
                  sky: "梦幻的粉色和淡紫色棉花糖一样的云朵天空"),
    ]
}
