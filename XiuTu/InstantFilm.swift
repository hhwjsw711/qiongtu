import CoreGraphics
import CoreImage
import Foundation
import simd

/// 即显相纸的规格。尺寸（毫米）是按各种相纸公开的规格取的近似值，
/// 颜色也是自己调的模拟，都不是任何厂商的官方配置。
enum InstantFormat: String, CaseIterable, Identifiable, Codable {
    case none, polaroid, go, mini, square, wide, spectra, peel, large

    var id: String { rawValue }

    struct Spec {
        /// 整张相纸。
        let paper: CGSize
        /// 画面。
        let image: CGSize
        /// 画面上方那条边；下方写字的宽边 = 剩下的。
        let top: CGFloat
        /// 画面四角的小圆角。
        var imageRadius: CGFloat = 0
        /// 相纸四角的圆角（只有开了投影、相纸四周露出底色时才看得到）。
        var paperRadius: CGFloat = 0.8
        /// 正面的质感，"实物"模式用。
        var surface: InstantSurface = .matte
    }

    var spec: Spec? {
        switch self {
        case .none:
            return nil
        case .polaroid:
            // 方形宝丽来（600 / SX-70 / i-Type 这一类）：88×107，画面 79×79。
            return Spec(paper: CGSize(width: 88, height: 107), image: CGSize(width: 79, height: 79), top: 6)
        case .go:
            // 小号方形：54×67，画面 47×46。
            return Spec(paper: CGSize(width: 54, height: 67), image: CGSize(width: 47, height: 46), top: 4.5,
                        paperRadius: 0.6)
        case .mini:
            // mini：54×86，画面 46×62。
            return Spec(paper: CGSize(width: 54, height: 86), image: CGSize(width: 46, height: 62), top: 7,
                        imageRadius: 0.9, paperRadius: 2.6, surface: .glossy)
        case .square:
            // 方形 SQ：72×86，画面 62×62。
            return Spec(paper: CGSize(width: 72, height: 86), image: CGSize(width: 62, height: 62), top: 7,
                        imageRadius: 0.9, paperRadius: 2.6, surface: .glossy)
        case .wide:
            // 宽幅：108×86，画面 99×62。
            return Spec(paper: CGSize(width: 108, height: 86), image: CGSize(width: 99, height: 62), top: 7,
                        imageRadius: 0.9, paperRadius: 2.6, surface: .glossy)
        case .spectra:
            // Spectra / Image 宽幅：102×103，画面 91×73。
            return Spec(paper: CGSize(width: 102, height: 103), image: CGSize(width: 91, height: 73), top: 7)
        case .peel:
            // 撕拉片：108×85，画面 95×73，四周是差不多宽的白边。
            return Spec(paper: CGSize(width: 108, height: 85), image: CGSize(width: 95, height: 73), top: 6,
                        paperRadius: 0.3, surface: .peel)
        case .large:
            // 8×10 大画幅：216×274，画面 190×241。
            return Spec(paper: CGSize(width: 216, height: 274), image: CGSize(width: 190, height: 241), top: 12,
                        paperRadius: 0.5)
        }
    }
}

/// 相纸正面的质感：哑光纸框（宝丽来这一类）、光面塑料（mini / SQ / wide）、撕拉片。
enum InstantSurface {
    case matte, glossy, peel
}

/// "实物"模式下相纸底下的扫描台。
enum InstantBed: String, CaseIterable, Identifiable, Codable {
    case white, gray, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "白色扫描台"
        case .gray: return "浅灰"
        case .dark: return "深色"
        }
    }

    var color: FrameColor {
        switch self {
        case .white: return FrameColor(hex: 0xF1F1EF)
        case .gray: return FrameColor(hex: 0xC9CACB)
        case .dark: return FrameColor(hex: 0x18181A)
        }
    }
}

/// 摆好方向之后各条边有多宽（毫米）。
struct InstantGeometry {
    var image: CGSize
    var left: CGFloat
    var right: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var imageRadius: CGFloat
    var paperRadius: CGFloat
    /// 写字的那条宽边是不是转到了右侧。
    var chinOnRight: Bool

    var paper: CGSize { CGSize(width: left + image.width + right, height: top + image.height + bottom) }
}

extension InstantFormat.Spec {
    /// rotated = 把相纸横过来（或竖过来）拍：宽边转到右侧。
    func geometry(rotated: Bool) -> InstantGeometry {
        let side = (paper.width - image.width) / 2
        let chin = paper.height - image.height - top
        if rotated {
            return InstantGeometry(image: CGSize(width: image.height, height: image.width),
                                   left: top, right: chin, top: side, bottom: side,
                                   imageRadius: imageRadius, paperRadius: paperRadius, chinOnRight: true)
        }
        return InstantGeometry(image: image, left: side, right: side, top: top, bottom: chin,
                               imageRadius: imageRadius, paperRadius: paperRadius, chinOnRight: false)
    }
}

/// 即显胶片的几种色调。和相纸规格分开选。
enum InstantStock: String, CaseIterable, Identifiable, Codable {
    case classic, sx70, bold, clear, mono, expired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "经典"
        case .sx70: return "柔和"
        case .bold: return "浓郁"
        case .clear: return "清透"
        case .mono: return "黑白"
        case .expired: return "过期"
        }
    }

    var color: ColorParams {
        var c = ColorParams()
        switch self {
        case .classic:
            // 偏暖、发灰，黑位抬起来，暗部带一点青。
            c.contrast = 0.08; c.fade = 0.38; c.saturation = -0.14; c.temperature = 0.12; c.highlights = -0.2
            c.shadowTint = SIMD3(-0.022, 0.014, 0.03); c.highlightTint = SIMD3(0.04, 0.02, -0.03)
        case .sx70:
            // 更软、更淡，整体像蒙了一层奶油。
            c.contrast = -0.22; c.fade = 0.32; c.saturation = -0.22; c.temperature = 0.07; c.tint = 0.04
            c.brightness = 0.08
            c.shadowTint = SIMD3(0.0, 0.012, 0.022); c.highlightTint = SIMD3(0.03, 0.022, 0.0)
        case .bold:
            // 反差大、颜色重，暗部偏蓝。
            c.contrast = 0.32; c.saturation = 0.14; c.fade = 0.14; c.temperature = 0.08; c.shadows = -0.12
            c.shadowTint = SIMD3(-0.022, 0.0, 0.034); c.highlightTint = SIMD3(0.034, 0.012, -0.022)
        case .clear:
            // 干净通透，略偏冷偏绿。
            c.contrast = 0.18; c.saturation = 0.02; c.vibrance = 0.1; c.temperature = -0.05; c.tint = -0.16
            c.exposure = 0.04; c.fade = 0.1
            c.shadowTint = SIMD3(-0.012, 0.016, 0.012)
        case .mono:
            // 黑白，带一点暖调的相纸底色。
            c.mono = true; c.monoWeights = SIMD3(0.32, 0.54, 0.14); c.contrast = 0.22; c.fade = 0.2
            c.shadowTint = SIMD3(0.012, 0.006, 0.0); c.highlightTint = SIMD3(0.03, 0.016, -0.02)
        case .expired:
            // 过期相纸：发灰、偏洋红偏黄，暗部发紫。
            c.contrast = -0.16; c.fade = 0.55; c.saturation = -0.26; c.temperature = 0.2; c.tint = 0.3
            c.shadowTint = SIMD3(0.03, -0.004, 0.06); c.highlightTint = SIMD3(0.05, 0.026, -0.04)
        }
        return c
    }

    /// 四角压暗（中间显得亮一点）。
    var vignette: CGFloat {
        switch self {
        case .classic: return 0.2
        case .sx70: return 0.12
        case .bold: return 0.28
        case .clear: return 0.06
        case .mono: return 0.22
        case .expired: return 0.32
        }
    }

    /// 高光的柔光。
    var bloom: CGFloat {
        switch self {
        case .classic: return 0.12
        case .sx70: return 0.22
        case .expired: return 0.16
        default: return 0
        }
    }

    /// 把一张（已经裁好的）画面冲成这种色调。intensity 0...1。
    func develop(_ shot: CIImage, intensity: CGFloat) -> CIImage {
        guard intensity > 0 else { return shot }
        var out = ColorCube.apply(color, to: shot, cacheKey: "instant-" + rawValue)
        out = FX.bloom(out, amount: bloom)
        out = FX.vignette(out, amount: vignette)
        return intensity < 1 ? FX.mix(shot, out, t: intensity) : out
    }
}

/// 相纸的颜色。
enum InstantPaper {
    static let white = FrameColor(hex: 0xFBFAF6)
    static let cream = FrameColor(hex: 0xF3EADB)
    static let black = FrameColor(hex: 0x171717)

    static let all: [FrameColor] = [
        white, cream, black,
        FrameColor(hex: 0xF6D6DA), FrameColor(hex: 0xF8ECC2), FrameColor(hex: 0xD4EBDC),
        FrameColor(hex: 0xCFE3F3), FrameColor(hex: 0xDDD6F0),
    ]
}

/// 面板上的一个个选项：一种相纸规格，加上是不是横过来用。
struct InstantPreset: Identifiable {
    let id: String
    let title: String
    let format: InstantFormat
    var rotated = false

    static let all: [InstantPreset] = [
        InstantPreset(id: "polaroid", title: "宝丽来方形", format: .polaroid),
        InstantPreset(id: "go", title: "Go 小方", format: .go),
        InstantPreset(id: "mini", title: "mini 竖版", format: .mini),
        InstantPreset(id: "miniL", title: "mini 横版", format: .mini, rotated: true),
        InstantPreset(id: "square", title: "方形 SQ", format: .square),
        InstantPreset(id: "wide", title: "宽幅 wide", format: .wide),
        InstantPreset(id: "wideP", title: "wide 竖版", format: .wide, rotated: true),
        InstantPreset(id: "spectra", title: "Spectra 宽幅", format: .spectra),
        InstantPreset(id: "peel", title: "撕拉片", format: .peel),
        InstantPreset(id: "peelP", title: "撕拉片 竖版", format: .peel, rotated: true),
        InstantPreset(id: "large", title: "大画幅 8×10", format: .large),
    ]
}

/// 拍立得：把照片做成一张即显相纸的样子（按相纸比例裁切、加相纸边、套即显胶片的颜色），作为编辑历史里的一步。
/// 所有尺寸都是从画面宽度按相纸的毫米比例换算的，预览和原图导出的样子一样。相纸上不加颗粒。
struct InstantParams: Equatable, Codable {
    var format: InstantFormat = .none
    /// 相纸横过来用：写字的宽边转到右侧。
    var rotated = false
    var stock: InstantStock = .classic
    /// 色调的强度，0...1。
    var intensity: CGFloat = 1
    var paper: FrameColor = InstantPaper.white
    /// 取景位置，-1...1：照片比画面宽时左右移，比画面高时上下移（正数 = 往右 / 往下）。
    var shift: CGFloat = 0
    /// 写在宽边上的字。
    var caption = ""
    /// 相纸四周留一圈底色，带一点投影。
    var shadow = false
    /// 实物：像一张真的照片平放在扫描仪上扫出来的样子（有厚度、有贴着台面的影子）。
    var real = false
    /// 实物模式下的扫描台颜色。
    var bed: InstantBed = .white

    var isIdentity: Bool { format == .none }

    /// 写字用的字体（手写体）。
    static let captionFont = "BradleyHandITCTT-Bold"
    /// 开投影时相纸后面的底色。
    static let desk = FrameColor(hex: 0xE4E1DB)

    /// 照片是 size 这么大时，成品是多大。
    func outputSize(for size: CGSize) -> CGSize {
        guard let layout = layout(for: size) else { return size }
        return layout.canvas.size
    }

    private struct Layout {
        /// 从照片里取哪一块。
        var crop: CGRect
        /// 每毫米多少像素。
        var mm: CGFloat
        var canvas: CGRect
        var sheet: CGRect
        var window: CGRect
        var geometry: InstantGeometry
    }

    private func layout(for size: CGSize) -> Layout? {
        guard let spec = format.spec, size.width >= 4, size.height >= 4 else { return nil }
        let g = spec.geometry(rotated: rotated)
        let aspect = g.image.width / g.image.height
        var cw = size.width, ch = size.height
        if size.width / size.height > aspect {
            cw = max(2, (size.height * aspect).rounded())
        } else {
            ch = max(2, (size.width / aspect).rounded())
        }
        let t = min(max(shift, -1), 1)
        let x0 = ((size.width - cw) / 2 * (1 + t)).rounded()
        let y0 = ((size.height - ch) / 2 * (1 - t)).rounded()
        let mm = cw / g.image.width
        let left = max(1, (g.left * mm).rounded()), right = max(1, (g.right * mm).rounded())
        let top = max(1, (g.top * mm).rounded()), bottom = max(1, (g.bottom * mm).rounded())
        let paper = CGSize(width: left + cw + right, height: bottom + ch + top)
        let short = min(paper.width, paper.height)
        let margin = real ? max(3, (short * 0.075).rounded()) : (shadow ? max(2, (short * 0.09).rounded()) : 0)
        let canvas = CGRect(x: 0, y: 0, width: paper.width + margin * 2, height: paper.height + margin * 2)
        let sheet = CGRect(x: margin, y: margin, width: paper.width, height: paper.height)
        let window = CGRect(x: sheet.minX + left, y: sheet.minY + bottom, width: cw, height: ch)
        return Layout(crop: CGRect(x: x0, y: y0, width: cw, height: ch), mm: mm, canvas: canvas,
                      sheet: sheet, window: window, geometry: g)
    }

    func apply(to image: CIImage) -> CIImage {
        let photo = FrameKit.normalized(image)
        guard let l = layout(for: photo.extent.size) else { return image }
        let g = l.geometry
        let canvas = l.canvas, sheet = l.sheet, window = l.window, mm = l.mm

        // 画面：裁出来，冲成选的色调。
        var shot = photo.cropped(to: l.crop)
            .transformed(by: CGAffineTransform(translationX: -l.crop.minX, y: -l.crop.minY))
        shot = stock.develop(shot, intensity: intensity).cropped(to: CGRect(origin: .zero, size: l.crop.size))
        if real { return applyReal(l, shot: shot) }

        // 相纸。
        var out: CIImage
        var sheetMask: CIImage?
        if shadow {
            out = FrameKit.fill(Self.desk, canvas)
            let radius = g.paperRadius * mm
            let drop = sheet.offsetBy(dx: 0, dy: -sheet.minY * 0.22)
            out = FrameKit.shadow(of: drop, radius: radius, blur: sheet.minY * 0.42, alpha: 0.3, canvas: canvas, over: out)
            sheetMask = FrameKit.roundMask(sheet, radius: radius, canvas: canvas)
            out = FrameKit.paint(paper, mask: sheetMask, over: out)
        } else {
            out = FrameKit.fill(paper, canvas)
        }
        out = Self.toned(out, paper: paper, sheet: sheet, mask: sheetMask, canvas: canvas)

        // 画面放进相纸的窗口里。
        let placed = shot.transformed(by: CGAffineTransform(translationX: window.minX, y: window.minY))
        let radius = g.imageRadius * mm
        let windowMask = radius > 0.5 ? FrameKit.roundMask(window, radius: radius, canvas: canvas) : nil
        out = FrameKit.layer(placed, mask: windowMask, over: out)

        // 相纸的框比画面高出一点：画面边缘有一圈很淡的内阴影，再加一道细的压线。
        if let soft = Self.softRing(window, radius: radius, width: mm * 1.0, blur: mm * 0.5, canvas: canvas) {
            out = FrameKit.paint(.black, alpha: 0.17, mask: soft, over: out)
        }
        out = FrameKit.paint(.black, alpha: 0.2,
                             mask: FrameKit.strokeMask(window, radius: radius, lineWidth: max(1, mm * 0.1), canvas: canvas),
                             over: out)

        return captioned(out, l).cropped(to: canvas)
    }

    /// 宽边上的字。
    private func captioned(_ image: CIImage, _ l: Layout) -> CIImage {
        let g = l.geometry, sheet = l.sheet, window = l.window
        var out = image
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let ink = paper.isLight ? FrameColor(hex: 0x2A2D36) : FrameColor(hex: 0xECEAE4)
            // 字高跟着宽边走；宽边很窄的相纸（撕拉片）字也不能小到看不见。
            let band = g.chinOnRight ? sheet.maxX - window.maxX : window.minY - sheet.minY
            let size = min(max(band * 0.42, min(sheet.width, sheet.height) * 0.085), band * 0.85)
            if g.chinOnRight {
                let chin = CGRect(x: window.maxX, y: window.minY, width: band, height: window.height)
                if let label = FrameKit.textImage(text, font: Self.captionFont, height: size,
                                                  maxWidth: chin.height * 0.9, color: ink) {
                    let turned = FrameKit.normalized(label.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)))
                    let x = (chin.midX - turned.extent.width / 2).rounded()
                    let y = (chin.midY - turned.extent.height / 2).rounded()
                    out = turned.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: out)
                }
            } else {
                let chin = CGRect(x: window.minX, y: sheet.minY, width: window.width, height: band)
                if let label = FrameKit.textImage(text, font: Self.captionFont, height: size,
                                                  maxWidth: chin.width * 0.92, color: ink) {
                    let x = (chin.midX - label.extent.width / 2).rounded()
                    let y = (chin.midY - label.extent.height / 2).rounded()
                    out = label.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: out)
                }
            }
        }
        return out
    }

    /// 相纸不是一块死平的颜色：边角比中间略深、略暖一点（深色相纸是一层很淡的反光）。只有明暗，没有颗粒。
    private static func toned(_ image: CIImage, paper: FrameColor, sheet: CGRect, mask: CIImage?, canvas: CGRect,
                              strength: CGFloat = 1) -> CIImage {
        let light = paper.isLight
        let tint = light ? CIColor(red: 0.42, green: 0.3, blue: 0.16, alpha: 0.07 * strength)
                         : CIColor(red: 1, green: 1, blue: 1, alpha: 0.014 * strength)
        let clear = CIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 0)
        var out = image
        let diagonal = hypot(sheet.width, sheet.height)
        // 浅色相纸：四角略深；深色相纸：左上角一片淡淡的亮。
        if light, let edge = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: sheet.midX, y: sheet.midY),
            "inputRadius0": diagonal * 0.3,
            "inputRadius1": diagonal * 0.62,
            "inputColor0": clear,
            "inputColor1": tint,
        ])?.outputImage {
            out = edge.cropped(to: canvas).composited(over: out)
        }
        let from = light ? CGPoint(x: sheet.maxX, y: sheet.minY) : CGPoint(x: sheet.minX, y: sheet.maxY)
        let to = light ? CGPoint(x: sheet.minX, y: sheet.maxY) : CGPoint(x: sheet.midX, y: sheet.midY)
        if let sweep = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: from.x, y: from.y),
            "inputPoint1": CIVector(x: to.x, y: to.y),
            "inputColor0": light ? CIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 0.045 * strength) : tint,
            "inputColor1": clear,
        ])?.outputImage {
            out = sweep.cropped(to: canvas).composited(over: out)
        }
        out = out.cropped(to: canvas)
        // 开了投影时相纸外面还有底色，那一圈不能跟着变。
        guard let mask else { return out }
        return FrameKit.layer(out, mask: mask, over: image)
    }

    /// 贴着窗口内侧的一圈虚边（内阴影用）。本来就是糊的，在缩小的图上做再放大，大图也不慢。
    private static func softRing(_ rect: CGRect, radius: CGFloat, width: CGFloat, blur: CGFloat, canvas: CGRect) -> CIImage? {
        guard width > 0, blur > 0 else { return nil }
        let k = min(1, 900 / max(canvas.width, canvas.height))
        let lw = max(1, (canvas.width * k).rounded()), lh = max(1, (canvas.height * k).rounded())
        let kx = lw / canvas.width, ky = lh / canvas.height
        let low = CGRect(x: 0, y: 0, width: lw, height: lh)
        let r = CGRect(x: rect.minX * kx, y: rect.minY * ky, width: rect.width * kx, height: rect.height * ky)
        let scale = min(kx, ky)
        guard let ring = FrameKit.strokeMask(r, radius: radius * scale, lineWidth: max(1, width * scale), canvas: low),
              let inside = FrameKit.roundMask(r, radius: radius * scale, canvas: low) else { return nil }
        return ring.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(blur * scale, 0.4)])
            .cropped(to: low)
            // 只留在画面里面，不能糊到相纸上。
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: inside])
            .transformed(by: CGAffineTransform(scaleX: 1 / kx, y: 1 / ky))
            .cropped(to: canvas)
    }
}

// MARK: - 实物

/// "实物"模式用到的作图工具。软的东西都在缩小的画布上做再放大：大图也不慢，而且各种尺寸下是同一个样子。
enum InstantKit {
    /// 药膜边缘不整齐的那一圈。n = 低频起伏；rc = 窗口 (minX, minY, maxX, maxY)；w = 左、右、下、上四条边各自的宽度（像素）。
    private static let fringeKernel = CIColorKernel(source: """
    kernel vec4 xtInstantFringe(__sample n, vec4 rc, vec4 w, float soft) {
        vec2 d = destCoord();
        float k = clamp(n.r * 2.3 - 0.4, 0.0, 1.9);
        float l = (1.0 - smoothstep(w.x * k - soft, w.x * k + soft, d.x - rc.x)) * step(0.001, w.x);
        float r = (1.0 - smoothstep(w.y * k - soft, w.y * k + soft, rc.z - d.x)) * step(0.001, w.y);
        float b = (1.0 - smoothstep(w.z * k - soft, w.z * k + soft, d.y - rc.y)) * step(0.001, w.z);
        float t = (1.0 - smoothstep(w.w * k - soft, w.w * k + soft, rc.w - d.y)) * step(0.001, w.w);
        float m = max(max(l, r), max(b, t));
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 调试用：哪些 kernel 没编译过（正常应该是空的）。
    static var brokenKernels: [String] { fringeKernel == nil ? ["fringe"] : [] }

    private static func scaled(_ r: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
    }

    /// 在长边不超过 limit 的小画布上搭一张图，再放大回 canvas 那么大。
    static func lowRes(_ canvas: CGRect, limit: CGFloat, _ build: (_ low: CGRect, _ k: CGFloat) -> CIImage?) -> CIImage? {
        let k = min(1, limit / max(canvas.width, canvas.height))
        if k >= 1 { return build(canvas, 1)?.cropped(to: canvas) }
        let lw = max(1, (canvas.width * k).rounded()), lh = max(1, (canvas.height * k).rounded())
        let low = CGRect(x: 0, y: 0, width: lw, height: lh)
        guard let made = build(low, k) else { return nil }
        return made.cropped(to: low)
            .transformed(by: CGAffineTransform(scaleX: canvas.width / lw, y: canvas.height / lh))
            .cropped(to: canvas)
    }

    /// 边缘虚化的圆角矩形（影子用）。
    static func softRect(_ rect: CGRect, radius: CGFloat, blur: CGFloat, canvas: CGRect) -> CIImage? {
        lowRes(canvas, limit: 1500) { low, k in
            FrameKit.roundMask(scaled(rect, k), radius: radius * k, canvas: low)?
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(blur * k, 0.3)])
        }
    }

    /// rect 的边上一条窄带。光从左上来：lit = 靠光的那两条边（上、左），否则是背光的两条（下、右）；
    /// inside = 带子在 rect 里面还是外面。
    static func band(_ rect: CGRect, radius: CGFloat, depth: CGFloat, lit: Bool, inside: Bool,
                     blur: CGFloat = 0, canvas: CGRect) -> CIImage? {
        lowRes(canvas, limit: blur > 0 ? 1800 : .greatestFiniteMagnitude) { low, k in
            let r = scaled(rect, k), d = depth * k, rad = radius * k
            let toShade = CGVector(dx: d, dy: -d), toLight = CGVector(dx: -d, dy: d)
            let a: CGRect, b: CGRect
            if inside {
                a = r
                b = lit ? r.offsetBy(dx: toShade.dx, dy: toShade.dy) : r.offsetBy(dx: toLight.dx, dy: toLight.dy)
            } else {
                a = lit ? r.offsetBy(dx: toLight.dx, dy: toLight.dy) : r.offsetBy(dx: toShade.dx, dy: toShade.dy)
                b = r
            }
            guard let ma = FrameKit.roundMask(a, radius: rad, canvas: low),
                  let mb = FrameKit.roundMask(b, radius: rad, canvas: low) else { return nil }
            // 在 a 里面、又不在 b 里面的那一条。
            var m = ma.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: mb.applyingFilter("CIColorInvert"),
            ])
            if blur > 0 {
                m = m.cropped(to: low).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(blur * k, 0.3)])
            }
            return m
        }
    }

    /// 低频的不规则起伏（灰度 0...1，一格大约 cell 像素）。花样只跟 seed 和画布比例有关，和分辨率无关。
    static func blotches(canvas: CGRect, cell: CGFloat, seed: CGPoint) -> CIImage? {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let mono = noise
            .transformed(by: CGAffineTransform(translationX: -seed.x, y: -seed.y))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        return lowRes(canvas, limit: 640) { low, k in
            let step = max(cell * k, 1.5)
            let c: CGFloat = 2.6
            return mono
                .transformed(by: CGAffineTransform(scaleX: step, y: step))
                .cropped(to: low.insetBy(dx: -step * 3, dy: -step * 3))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: step * 0.55])
                // 糊开以后起伏变小了，拉回来。
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: c, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: c, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: c, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - 0.5 * c, y: 0.5 - 0.5 * c, z: 0.5 - 0.5 * c, w: 1),
                ])
                .applyingFilter("CIColorClamp")
        }
    }

    /// 药膜边缘不整齐的那一圈（白 = 有）。widths 是左、右、下、上四条边的宽度。
    static func fringe(_ rect: CGRect, left: CGFloat, right: CGFloat, bottom: CGFloat, top: CGFloat,
                       soft: CGFloat, noise: CIImage, canvas: CGRect) -> CIImage? {
        fringeKernel?.apply(extent: canvas, arguments: [
            noise, CIVector(x: rect.minX, y: rect.minY, z: rect.maxX, w: rect.maxY),
            CIVector(x: left, y: right, z: bottom, w: top), NSNumber(value: Double(max(soft, 0.5))),
        ])
    }

    /// 纸框上很淡的纸纹：顺着一个方向的细丝。只有明暗，位置固定。
    static func fibre(_ image: CIImage, mm: CGFloat, amount: CGFloat, vertical: Bool, canvas: CGRect) -> CIImage {
        guard amount > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let along = max(mm * 0.5, 1), across = max(mm * 0.085, 1)
        let layer = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: amount),
            ])
            .transformed(by: CGAffineTransform(scaleX: vertical ? across : along, y: vertical ? along : across))
            .cropped(to: canvas)
        return layer.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: canvas)
    }
}

extension InstantParams {
    /// "实物"：相纸像一张真的照片平放在扫描仪上扫出来的样子——相纸有厚度、纸框比画面高一层、药膜边缘不那么整齐、
    /// 贴着台面有一圈很窄的影子。光从左上来。画面本身不加颗粒；纸框上的纸纹很淡，位置固定，预览和导出一样。
    private func applyReal(_ l: Layout, shot: CIImage) -> CIImage {
        let g = l.geometry
        let canvas = l.canvas, sheet = l.sheet, window = l.window, mm = l.mm
        let surface = format.spec?.surface ?? .matte
        let light = paper.isLight
        let black = FrameColor.black, white = FrameColor.white
        let paperRadius = max(g.paperRadius, 0.55) * mm
        let imageRadius = max(g.imageRadius, surface == .peel ? 0.15 : 0.3) * mm
        // 每种相纸的起伏花样错开。
        let n = CGFloat(InstantFormat.allCases.firstIndex(of: format) ?? 0)
        let seedA = CGPoint(x: 11 + n * 37, y: 5 + n * 19), seedB = CGPoint(x: 301 + n * 13, y: 211 + n * 29)
        let seedC = CGPoint(x: 97 + n * 23, y: 409 + n * 7)

        // 扫描台：一头略暗一点。
        var out = FrameKit.fill(bed.color, canvas)
        if let falloff = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: canvas.maxX, y: canvas.midY),
            "inputPoint1": CIVector(x: canvas.minX + canvas.width * 0.35, y: canvas.midY),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.05),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage {
            out = falloff.cropped(to: canvas).composited(over: out)
        }
        // 相纸贴着台面：四周一圈很窄的影子，背光的右、下两条边更重。
        out = FrameKit.paint(black, alpha: 0.2,
                             mask: InstantKit.softRect(sheet.insetBy(dx: -mm * 0.25, dy: -mm * 0.25), radius: paperRadius,
                                                       blur: mm * 0.9, canvas: canvas), over: out)
        out = FrameKit.paint(black, alpha: 0.5,
                             mask: InstantKit.softRect(sheet.offsetBy(dx: mm * 0.55, dy: -mm * 0.65), radius: paperRadius,
                                                       blur: mm * 0.4, canvas: canvas), over: out)

        // 相纸正面：边角发黄，纸面深浅不匀。
        var face = FrameKit.fill(paper, canvas)
        face = Self.toned(face, paper: paper, sheet: sheet, mask: nil, canvas: canvas, strength: light ? 1.8 : 1)
        if let blot = InstantKit.blotches(canvas: canvas, cell: mm * 11, seed: seedA) {
            // 合成是在线性光里做的，一点点白落在深色上就很亮，所以深色相纸上的白都给得很小。
            face = FrameKit.paint(light ? FrameColor(hex: 0x8A7453) : white, alpha: light ? 0.05 : 0.006, mask: blot, over: face)
        }
        if surface == .matte {
            face = InstantKit.fibre(face, mm: mm, amount: light ? 0.1 : 0.035, vertical: g.chinOnRight, canvas: canvas)
            // 窗口外面一圈是压出来的边，比纸面略高：整圈亮一点，靠光的外沿一线亮，背光的外沿一线暗。
            let rim = window.insetBy(dx: -mm * 0.9, dy: -mm * 0.9)
            let rimRadius = imageRadius + mm * 0.45
            face = FrameKit.paint(white, alpha: light ? 0.3 : 0.01,
                                  mask: FrameKit.strokeMask(rim, radius: rimRadius, lineWidth: mm * 0.9, canvas: canvas), over: face)
            face = FrameKit.paint(white, alpha: light ? 0.5 : 0.03,
                                  mask: InstantKit.band(rim, radius: rimRadius, depth: mm * 0.14, lit: true, inside: true,
                                                        canvas: canvas), over: face)
            face = FrameKit.paint(black, alpha: 0.09,
                                  mask: InstantKit.band(rim, radius: rimRadius, depth: mm * 0.16, lit: false, inside: false,
                                                        canvas: canvas), over: face)
        }
        // 宽边里药包压出来的那道棱（撕拉片没有）：上沿亮、下沿暗。
        if surface != .peel {
            let depth: CGFloat = surface == .matte ? 0.27 : 0.17
            let strength: CGFloat = surface == .matte ? 1 : 0.6
            let t = max(1, (mm * 0.14).rounded())
            let lit: CGRect, shade: CGRect
            if g.chinOnRight {
                let x = (sheet.maxX - (sheet.maxX - window.maxX) * depth).rounded()
                lit = CGRect(x: x, y: sheet.minY + mm * 3, width: t, height: sheet.height - mm * 6)
                shade = lit.offsetBy(dx: t, dy: 0)
            } else {
                let y = (sheet.minY + (window.minY - sheet.minY) * depth).rounded()
                lit = CGRect(x: sheet.minX + mm * 3, y: y, width: sheet.width - mm * 6, height: t)
                shade = lit.offsetBy(dx: 0, dy: -t)
            }
            face = FrameKit.paint(white, alpha: (light ? 0.6 : 0.03) * strength,
                                  mask: FrameKit.roundMask(lit, radius: 0, canvas: canvas), over: face)
            face = FrameKit.paint(black, alpha: 0.11 * strength,
                                  mask: FrameKit.roundMask(shade, radius: 0, canvas: canvas), over: face)
        }

        // 画面。先整块放上去做完效果，最后按窗口的形状嵌进纸框。
        let placed = shot.transformed(by: CGAffineTransform(translationX: window.minX, y: window.minY))
        var picture = placed.composited(over: face).cropped(to: canvas)
        // 越靠边越暗一点。
        if let falloff = Self.softRing(window, radius: imageRadius, width: mm * 1.8, blur: mm * 1.1, canvas: canvas) {
            picture = FrameKit.paint(black, alpha: 0.2, mask: falloff, over: picture)
        }
        // 表面的反光：光面相纸更明显。
        if let sheen = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: window.minX + window.width * 0.1, y: window.maxY),
            "inputPoint1": CIVector(x: window.minX + window.width * 0.7, y: window.minY + window.height * 0.3),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: surface == .glossy ? 0.1 : 0.06),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])?.outputImage {
            picture = sheen.cropped(to: canvas).composited(over: picture).cropped(to: canvas)
        }
        // 药膜边缘不是一刀切的：一圈宽窄不匀的深色边；宝丽来靠药包那一侧还有一点浅色的药痕，撕拉片有一侧特别宽。
        if let wave = InstantKit.blotches(canvas: canvas, cell: mm * 2.4, seed: seedB) {
            let soft = mm * 0.07
            switch surface {
            case .matte:
                picture = FrameKit.paint(FrameColor(hex: 0x17120E), alpha: 0.7,
                                         mask: InstantKit.fringe(window, left: mm * 0.2, right: mm * 0.2, bottom: mm * 0.16,
                                                                 top: mm * 0.2, soft: soft, noise: wave, canvas: canvas),
                                         over: picture)
                if let streak = InstantKit.blotches(canvas: canvas, cell: mm * 3.4, seed: seedC) {
                    let onRight = g.chinOnRight
                    picture = FrameKit.paint(FrameColor(hex: 0xFFF0C4), alpha: 0.3,
                                             mask: InstantKit.fringe(window, left: 0, right: onRight ? mm * 0.6 : 0,
                                                                     bottom: onRight ? 0 : mm * 0.6, top: 0,
                                                                     soft: mm * 0.3, noise: streak, canvas: canvas),
                                             over: picture)
                }
            case .glossy:
                picture = FrameKit.paint(FrameColor(hex: 0x0C0C0E), alpha: 0.6,
                                         mask: InstantKit.fringe(window, left: mm * 0.09, right: mm * 0.09, bottom: mm * 0.09,
                                                                 top: mm * 0.09, soft: mm * 0.05, noise: wave, canvas: canvas),
                                         over: picture)
            case .peel:
                picture = FrameKit.paint(FrameColor(hex: 0x24170C), alpha: 0.9,
                                         mask: InstantKit.fringe(window, left: mm * 0.35, right: mm * 1.7, bottom: mm * 0.6,
                                                                 top: mm * 0.35, soft: mm * 0.1, noise: wave, canvas: canvas),
                                         over: picture)
            }
        }
        face = FrameKit.layer(picture, mask: FrameKit.roundMask(window, radius: imageRadius, canvas: canvas), over: face)

        // 纸框压在画面上，画面比纸框低一层：靠光的上、左两条边，纸框的影子落在画面里；背光的两条边露出切口的亮边。
        face = FrameKit.paint(black, alpha: 0.46,
                              mask: InstantKit.band(window, radius: imageRadius, depth: mm * 0.5, lit: true, inside: true,
                                                    blur: mm * 0.2, canvas: canvas), over: face)
        face = FrameKit.paint(black, alpha: 0.3,
                              mask: FrameKit.strokeMask(window, radius: imageRadius, lineWidth: max(1, mm * 0.09), canvas: canvas),
                              over: face)
        face = FrameKit.paint(white, alpha: light ? 0.75 : 0.07,
                              mask: InstantKit.band(window, radius: imageRadius, depth: mm * 0.16, lit: false, inside: false,
                                                    canvas: canvas), over: face)
        face = FrameKit.paint(black, alpha: 0.08,
                              mask: InstantKit.band(window, radius: imageRadius, depth: mm * 0.18, lit: true, inside: false,
                                                    canvas: canvas), over: face)

        face = captioned(face, l)

        // 相纸本身的厚度：靠光的两条边一线亮，背光的两条边一线暗，再往里是面纸和底纸压合的那道缝。
        face = FrameKit.paint(white, alpha: light ? 0.7 : 0.06,
                              mask: InstantKit.band(sheet, radius: paperRadius, depth: mm * 0.28, lit: true, inside: true,
                                                    canvas: canvas), over: face)
        face = FrameKit.paint(black, alpha: 0.17,
                              mask: InstantKit.band(sheet, radius: paperRadius, depth: mm * 0.42, lit: false, inside: true,
                                                    blur: mm * 0.12, canvas: canvas), over: face)
        let seam = sheet.insetBy(dx: mm * 0.65, dy: mm * 0.65)
        face = FrameKit.paint(black, alpha: surface == .matte ? 0.07 : 0.04,
                              mask: FrameKit.strokeMask(seam, radius: max(paperRadius - mm * 0.65, 0),
                                                        lineWidth: max(1, mm * 0.09), canvas: canvas), over: face)
        if surface == .glossy, let gloss = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: sheet.minX, y: sheet.maxY),
            "inputPoint1": CIVector(x: sheet.minX + sheet.width * 0.6, y: sheet.minY + sheet.height * 0.4),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.07),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])?.outputImage {
            // 整张都是光面塑料，从一角扫过来一片很淡的反光。
            face = gloss.cropped(to: canvas).composited(over: face).cropped(to: canvas)
        }
        face = FrameKit.paint(black, alpha: 0.22,
                              mask: FrameKit.strokeMask(sheet, radius: paperRadius, lineWidth: max(1, mm * 0.07), canvas: canvas),
                              over: face)

        out = FrameKit.layer(face, mask: FrameKit.roundMask(sheet, radius: paperRadius, canvas: canvas), over: out)
        return out.cropped(to: canvas)
    }
}
