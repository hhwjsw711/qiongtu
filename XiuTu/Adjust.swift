import CoreImage
import Foundation
import simd

enum AdjustGroup: String, CaseIterable, Identifiable {
    case light, color, detail, tone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "光效"
        case .color: return "色彩"
        case .detail: return "细节"
        case .tone: return "光影"
        }
    }

    /// 这一组里用滑块直接调的项目（不含子面板和 AI 功能）。
    var keys: [AdjustKey] { AdjustKey.allCases.filter { $0.group == self } }
}

/// 一个滑块对应一项。全部在本机算，不联网。
enum AdjustKey: String, CaseIterable, Identifiable, Codable {
    // 光效
    case brightness, contrast, exposure, lightSense, highlights, shadows, ambiance, fillLight
    // 色彩
    case saturation, vibrance, temperature, tint, dehaze, fade
    // 细节
    case sharpen, clarity, denoise, grain, fringe, vignette
    // 光影
    case naturalLight, lowLight, backlight, evenLight, moodLight, bloom
    // 肤色调整（在子面板里，不出现在一排按钮上）
    case skinTone, skinWhiten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightness: return "亮度"
        case .contrast: return "对比度"
        case .exposure: return "曝光"
        case .lightSense: return "光感"
        case .highlights: return "高光"
        case .shadows: return "暗部"
        case .ambiance: return "氛围"
        case .fillLight: return "智能补光"
        case .saturation: return "饱和度"
        case .vibrance: return "自然饱和度"
        case .temperature: return "色温"
        case .tint: return "色调"
        case .dehaze: return "去灰"
        case .fade: return "褪色"
        case .sharpen: return "锐化"
        case .clarity: return "清晰度"
        case .denoise: return "降噪"
        case .grain: return "颗粒"
        case .fringe: return "色散"
        case .vignette: return "暗角"
        case .naturalLight: return "自然光"
        case .lowLight: return "弱光"
        case .backlight: return "逆光"
        case .evenLight: return "校正光"
        case .moodLight: return "氛围光"
        case .bloom: return "柔光"
        case .skinTone: return "肤色"
        case .skinWhiten: return "白皙"
        }
    }

    var symbol: String {
        switch self {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .exposure: return "plusminus.circle"
        case .lightSense: return "sun.min"
        case .highlights: return "sun.haze"
        case .shadows: return "moon"
        case .ambiance: return "circle.hexagongrid"
        case .fillLight: return "lightbulb"
        case .saturation: return "drop"
        case .vibrance: return "sparkles"
        case .temperature: return "thermometer.medium"
        case .tint: return "eyedropper"
        case .dehaze: return "sun.dust"
        case .fade: return "cloud.fog"
        case .sharpen: return "triangle"
        case .clarity: return "diamond"
        case .denoise: return "circle.dotted"
        case .grain: return "aqi.medium"
        case .fringe: return "lightspectrum.horizontal"
        case .vignette: return "smallcircle.filled.circle"
        case .naturalLight: return "sun.horizon"
        case .lowLight: return "moon.stars"
        case .backlight: return "sunset"
        case .evenLight: return "camera.metering.matrix"
        case .moodLight: return "light.beacon.max"
        case .bloom: return "light.max"
        case .skinTone, .skinWhiten: return "face.smiling"
        }
    }

    /// 属于哪一组；nil = 只在子面板里出现。
    var group: AdjustGroup? {
        switch self {
        case .brightness, .contrast, .exposure, .lightSense, .highlights, .shadows, .ambiance, .fillLight: return .light
        case .saturation, .vibrance, .temperature, .tint, .dehaze, .fade: return .color
        case .sharpen, .clarity, .denoise, .grain, .fringe, .vignette: return .detail
        case .naturalLight, .lowLight, .backlight, .evenLight, .moodLight, .bloom: return .tone
        case .skinTone, .skinWhiten: return nil
        }
    }

    /// true = 滑块范围 -100...100；false = 0...100。
    var bipolar: Bool {
        switch self {
        case .sharpen, .denoise, .grain, .fade, .bloom, .dehaze, .fringe,
             .fillLight, .naturalLight, .lowLight, .backlight, .evenLight, .skinWhiten:
            return false
        default:
            return true
        }
    }

    /// 需要先算出"这一带整体有多亮"才能做的项目（补光、逆光这类按区域提亮压暗的）。
    static let localToneKeys: [AdjustKey] = [.fillLight, .backlight, .ambiance, .naturalLight, .evenLight]
}

/// 调色里要进子面板调的项目。
enum AdjustSub: String, Identifiable {
    case local, hsl, skin, split, curve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "局部调色"
        case .hsl: return "HSL"
        case .skin: return "肤色调整"
        case .split: return "色调分离"
        case .curve: return "曲线"
        }
    }

    var symbol: String {
        switch self {
        case .local: return "scope"
        case .hsl: return "paintpalette"
        case .skin: return "face.smiling"
        case .split: return "circle.lefthalf.striped.horizontal"
        case .curve: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

/// HSL 里的八个颜色。顺序和 AdjustFX 里 HSL 着色器的色带一一对应。
enum HSLColor: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .aqua: return "青"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .magenta: return "洋红"
        }
    }

    /// 这个颜色的中心色相（0...1）。
    var hue: Double {
        switch self {
        case .red: return 0
        case .orange: return 30.0 / 360
        case .yellow: return 60.0 / 360
        case .green: return 120.0 / 360
        case .aqua: return 180.0 / 360
        case .blue: return 240.0 / 360
        case .purple: return 280.0 / 360
        case .magenta: return 320.0 / 360
        }
    }
}

/// 曲线：总曲线 + 红绿蓝三条。每条是一串控制点（x、y 都是 0...1，x 递增），至少有头尾两个点。
struct CurveSet: Equatable, Codable {
    static let identity: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    /// 下标：0 = 总曲线（三个通道一起），1 = 红，2 = 绿，3 = 蓝。
    var channels: [[CGPoint]] = Array(repeating: CurveSet.identity, count: 4)

    var isIdentity: Bool { channels.allSatisfy { $0 == CurveSet.identity } }

    func isChanged(_ channel: Int) -> Bool { channels[channel] != CurveSet.identity }
}

/// 色调分离：给暗部和亮部各染一个颜色。
struct SplitTone: Equatable, Codable {
    /// 色相 0...1。
    var shadowHue: Float = 0.6
    var shadowAmount: Float = 0
    var highlightHue: Float = 0.1
    var highlightAmount: Float = 0
    /// -1...1：往左暗部的颜色占得多，往右亮部的颜色占得多。
    var balance: Float = 0

    var isIdentity: Bool { shadowAmount == 0 && highlightAmount == 0 }
}

/// 局部调色的一个点：只改以它为中心的一个圆里面，边缘渐变过渡。
struct LocalAdjust: Equatable, Identifiable, Codable {
    var id = UUID()
    /// 中心，归一化图片坐标，原点左上角。
    var center: CGPoint
    /// 范围半径，以图片长边为 1。
    var radius: Float = 0.22
    var brightness: Float = 0
    var contrast: Float = 0
    var saturation: Float = 0
    var temperature: Float = 0

    var isNeutral: Bool { brightness == 0 && contrast == 0 && saturation == 0 && temperature == 0 }
}

/// 调色面板自己的界面状态（开着哪个子面板、选中哪个颜色……）。不算进"改了什么"。
struct AdjustUI {
    var sub: AdjustSub?
    var hslColor: HSLColor = .red
    var curveChannel = 0
    var localID: UUID?
}

struct AdjustParams: Equatable, Codable {
    /// 存配方时只存数值，不存界面状态。
    private enum CodingKeys: String, CodingKey { case values, hsl, curves, split, locals }

    private(set) var values: [AdjustKey: Float] = [:]
    /// HSL：每个颜色的（色相、饱和度、明度），都是 -1...1。下标是 HSLColor.rawValue。
    var hsl = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: HSLColor.allCases.count)
    var curves = CurveSet()
    var split = SplitTone()
    var locals: [LocalAdjust] = []
    var ui = AdjustUI()

    subscript(key: AdjustKey) -> Float {
        get { values[key] ?? 0 }
        set { values[key] = newValue == 0 ? nil : newValue }
    }

    /// 界面状态不参与比较。
    static func == (a: AdjustParams, b: AdjustParams) -> Bool {
        a.values == b.values && a.hsl == b.hsl && a.curves == b.curves && a.split == b.split && a.locals == b.locals
    }

    var hslChanged: Bool { hsl.contains { $0 != SIMD3<Float>(0, 0, 0) } }
    var skinChanged: Bool { self[.skinTone] != 0 || self[.skinWhiten] != 0 }
    var localChanged: Bool { locals.contains { !$0.isNeutral } }

    func isChanged(_ sub: AdjustSub) -> Bool {
        switch sub {
        case .local: return localChanged
        case .hsl: return hslChanged
        case .skin: return skinChanged
        case .split: return !split.isIdentity
        case .curve: return !curves.isIdentity
        }
    }

    var isIdentity: Bool {
        values.isEmpty && !hslChanged && curves.isIdentity && split.isIdentity && !localChanged
    }

    /// 交给 3D LUT 一次算完的那几项。
    var color: ColorParams {
        var c = ColorParams()
        c.exposure = self[.exposure]
        c.brightness = self[.brightness]
        c.contrast = self[.contrast]
        c.highlights = self[.highlights]
        c.shadows = self[.shadows]
        c.saturation = self[.saturation]
        c.vibrance = self[.vibrance]
        c.temperature = self[.temperature]
        c.tint = self[.tint]
        c.fade = self[.fade]
        return c
    }

    /// 所有半径都按图片尺寸折算，预览图和原图导出效果一致。
    func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let extent = image.extent
        let dim = max(extent.width, extent.height)
        var out = image

        let denoise = CGFloat(self[.denoise])
        if denoise > 0 {
            out = out.clampedToExtent()
                .applyingFilter("CINoiseReduction", parameters: [
                    "inputNoiseLevel": 0.01 + denoise * 0.07,
                    "inputSharpness": 0.4,
                ])
                .cropped(to: extent)
        }

        // 按区域提亮 / 压暗：智能补光、逆光、氛围、自然光、校正光。
        if AdjustKey.localToneKeys.contains(where: { self[$0] != 0 }) {
            out = AdjustFX.localTone(out, fill: self[.fillLight], backlight: self[.backlight], ambiance: self[.ambiance],
                                     natural: self[.naturalLight], even: self[.evenLight])
        }
        // 逐像素的光线：光感、弱光、自然光、氛围光。
        out = AdjustFX.light(out, sense: self[.lightSense], lowLight: self[.lowLight],
                             natural: self[.naturalLight], mood: self[.moodLight])

        out = ColorCube.apply(color, to: out)
        out = AdjustFX.curves(out, curves)
        if hslChanged { out = AdjustFX.hsl(out, hsl) }
        out = AdjustFX.skin(out, tone: self[.skinTone], whiten: self[.skinWhiten])
        out = AdjustFX.split(out, split)
        out = AdjustFX.dehaze(out, amount: self[.dehaze])
        out = AdjustFX.clarity(out, amount: self[.clarity])
        out = FX.unsharp(out, radius: dim * 0.0013, intensity: CGFloat(self[.sharpen]) * 1.6)
        for point in locals where !point.isNeutral {
            out = AdjustFX.local(out, point)
        }
        out = AdjustFX.fringe(out, amount: self[.fringe])
        // 自然光和氛围光都带一点高光的柔光晕。
        let glow = CGFloat(self[.bloom]) + 0.18 * CGFloat(self[.naturalLight]) + 0.2 * CGFloat(abs(self[.moodLight]))
        out = FX.bloom(out, amount: min(glow, 1))
        out = AdjustFX.vignette(out, amount: self[.vignette])
        out = FX.grain(out, amount: CGFloat(self[.grain]))
        return out.cropped(to: extent)
    }
}
