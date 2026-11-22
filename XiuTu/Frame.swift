import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// 边框、背景里用到的颜色（sRGB，0...1）。
struct FrameColor: Equatable, Hashable, Codable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    static let white = FrameColor(r: 1, g: 1, b: 1)
    static let black = FrameColor(r: 0, g: 0, b: 0)

    init(r: CGFloat, g: CGFloat, b: CGFloat) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    init(hex: UInt32) {
        self.init(r: CGFloat((hex >> 16) & 0xFF) / 255, g: CGFloat((hex >> 8) & 0xFF) / 255, b: CGFloat(hex & 0xFF) / 255)
    }

    var luma: CGFloat { 0.299 * r + 0.587 * g + 0.114 * b }
    var isLight: Bool { luma > 0.6 }

    /// 压在这个颜色上看得清的颜色（画线、打孔、写字用）。
    var contrast: FrameColor {
        isLight ? FrameColor(r: 0.13, g: 0.13, b: 0.14) : FrameColor(r: 0.93, g: 0.93, b: 0.92)
    }

    func ci(alpha: CGFloat = 1) -> CIColor {
        CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: FrameKit.sRGB)
            ?? CIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    var cg: CGColor {
        CGColor(colorSpace: FrameKit.sRGB, components: [r, g, b, 1]) ?? CGColor(gray: 0, alpha: 1)
    }
}

/// 边框和背景共用的作图工具。形状全部用 Core Image 按坐标算出来，图多大都一样清晰，不用画大位图。
enum FrameKit {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: 形状蒙版（白 = 有，黑 = 没有）

    /// 圆角矩形。rc = (minX, minY, maxX, maxY)。
    private static let roundKernel = CIColorKernel(source: """
    kernel vec4 xtFrameRound(vec4 rc, float rad) {
        vec2 d = destCoord();
        vec2 c = (rc.xy + rc.zw) * 0.5;
        vec2 hs = (rc.zw - rc.xy) * 0.5;
        vec2 q = abs(d - c) - (hs - vec2(rad));
        float dist = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - rad;
        float m = clamp(0.5 - dist, 0.0, 1.0);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 圆角矩形的一圈线，线画在边界以内。
    private static let strokeKernel = CIColorKernel(source: """
    kernel vec4 xtFrameStroke(vec4 rc, float rad, float lw) {
        vec2 d = destCoord();
        vec2 c = (rc.xy + rc.zw) * 0.5;
        vec2 hs = (rc.zw - rc.xy) * 0.5;
        vec2 q = abs(d - c) - (hs - vec2(rad));
        float dist = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - rad;
        float m = clamp(0.5 - (abs(dist + lw * 0.5) - lw * 0.5), 0.0, 1.0);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 一排圆角小方孔（胶片齿孔）。org = 第一个孔的中心，stp = 相邻两个孔中心的位移，hs = 孔的半宽半高。
    private static let holesKernel = CIColorKernel(source: """
    kernel vec4 xtFrameHoles(vec2 org, vec2 stp, float count, vec2 hs, float rad) {
        vec2 d = destCoord() - org;
        float len = length(stp);
        vec2 u = stp / len;
        float idx = clamp(floor(dot(d, u) / len + 0.5), 0.0, count - 1.0);
        vec2 q = abs(d - u * (idx * len)) - (hs - vec2(rad));
        float dist = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - rad;
        float m = clamp(0.5 - dist, 0.0, 1.0);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 邮票纸：矩形里面是 1，沿四条边按 pitch 排的圆孔里是 0。
    private static let perfKernel = CIColorKernel(source: """
    kernel vec4 xtFramePerf(vec4 rc, vec2 pitch, float rad) {
        vec2 d = destCoord();
        vec2 lo = rc.xy;
        vec2 hi = rc.zw;
        vec2 e = min(d - lo, hi - d);
        float inside = clamp(min(e.x, e.y) + 0.5, 0.0, 1.0);
        vec2 rel = d - lo;
        float nx = floor(rel.x / pitch.x + 0.5) * pitch.x;
        float ey = (d.y - lo.y < hi.y - d.y) ? lo.y : hi.y;
        float d1 = length(vec2(rel.x - nx, d.y - ey));
        float ny = floor(rel.y / pitch.y + 0.5) * pitch.y;
        float ex = (d.x - lo.x < hi.x - d.x) ? lo.x : hi.x;
        float d2 = length(vec2(d.x - ex, rel.y - ny));
        float hole = clamp(0.5 - (min(d1, d2) - rad), 0.0, 1.0);
        float m = inside * (1.0 - hole);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 格子。
    private static let checksKernel = CIColorKernel(source: """
    kernel vec4 xtFrameChecks(float cell) {
        vec2 c = floor(destCoord() / cell);
        float m = mod(c.x + c.y, 2.0);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 错开排列的波点。
    private static let dotsKernel = CIColorKernel(source: """
    kernel vec4 xtFrameDots(float cell, float rad) {
        vec2 d = destCoord();
        float row = floor(d.y / cell);
        float shift = mod(row, 2.0) * 0.5 * cell;
        vec2 q = vec2(mod(d.x + shift, cell), mod(d.y, cell)) - vec2(0.5 * cell);
        float m = clamp(0.5 - (length(q) - rad), 0.0, 1.0);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 斜条纹，条和空一样宽。dir 是垂直于条纹的单位向量。
    private static let stripesKernel = CIColorKernel(source: """
    kernel vec4 xtFrameStripes(float period, vec2 dir) {
        float t = dot(destCoord(), dir) / period;
        float f = t - floor(t);
        float e = 0.75 / period;
        float m = smoothstep(0.25 - e, 0.25 + e, f) - smoothstep(0.75 - e, 0.75 + e, f);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 调试用：哪些 kernel 没编译过（正常应该是空的）。
    static var brokenKernels: [String] {
        var bad: [String] = []
        if roundKernel == nil { bad.append("round") }
        if strokeKernel == nil { bad.append("stroke") }
        if holesKernel == nil { bad.append("holes") }
        if perfKernel == nil { bad.append("perf") }
        if checksKernel == nil { bad.append("checks") }
        if dotsKernel == nil { bad.append("dots") }
        if stripesKernel == nil { bad.append("stripes") }
        return bad
    }

    private static func num(_ v: CGFloat) -> NSNumber { NSNumber(value: Double(v)) }
    private static func vec(_ r: CGRect) -> CIVector { CIVector(x: r.minX, y: r.minY, z: r.maxX, w: r.maxY) }

    static func roundMask(_ rect: CGRect, radius: CGFloat, canvas: CGRect) -> CIImage? {
        let rad = min(max(radius, 0), min(rect.width, rect.height) / 2)
        return roundKernel?.apply(extent: canvas, arguments: [vec(rect), num(rad)])
    }

    static func strokeMask(_ rect: CGRect, radius: CGFloat, lineWidth: CGFloat, canvas: CGRect) -> CIImage? {
        let rad = min(max(radius, 0), min(rect.width, rect.height) / 2)
        return strokeKernel?.apply(extent: canvas, arguments: [vec(rect), num(rad), num(max(lineWidth, 0.01))])
    }

    static func holesMask(first: CGPoint, step: CGVector, count: Int, size: CGSize, radius: CGFloat, canvas: CGRect) -> CIImage? {
        guard count > 0, hypot(step.dx, step.dy) > 0 else { return nil }
        return holesKernel?.apply(extent: canvas, arguments: [
            CIVector(x: first.x, y: first.y), CIVector(x: step.dx, y: step.dy), num(CGFloat(count)),
            CIVector(x: size.width / 2, y: size.height / 2), num(min(radius, min(size.width, size.height) / 2)),
        ])
    }

    static func perfMask(_ rect: CGRect, pitch: CGSize, radius: CGFloat, canvas: CGRect) -> CIImage? {
        guard pitch.width > 0, pitch.height > 0 else { return nil }
        return perfKernel?.apply(extent: canvas, arguments: [vec(rect), CIVector(x: pitch.width, y: pitch.height), num(radius)])
    }

    static func checksMask(cell: CGFloat, canvas: CGRect) -> CIImage? {
        checksKernel?.apply(extent: canvas, arguments: [num(max(cell, 1))])
    }

    static func dotsMask(cell: CGFloat, radius: CGFloat, canvas: CGRect) -> CIImage? {
        dotsKernel?.apply(extent: canvas, arguments: [num(max(cell, 1)), num(radius)])
    }

    static func stripesMask(period: CGFloat, canvas: CGRect) -> CIImage? {
        stripesKernel?.apply(extent: canvas, arguments: [num(max(period, 2)), CIVector(x: 0.7071, y: 0.7071)])
    }

    // MARK: 拼装

    /// 把原点移到 (0,0)。
    static func normalized(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.minX != 0 || e.minY != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    static func fill(_ color: FrameColor, _ rect: CGRect) -> CIImage {
        CIImage(color: color.ci()).cropped(to: rect)
    }

    /// 在 below 上面按蒙版涂一层颜色。alpha 是这层颜色的不透明度。
    static func paint(_ color: FrameColor, alpha: CGFloat = 1, mask: CIImage?, over below: CIImage) -> CIImage {
        guard var mask else { return below }
        if alpha < 1 {
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
            ])
        }
        return fill(color, below.extent).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: below,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: below.extent)
    }

    /// 把 top 叠到 below 上。给了蒙版就只露出蒙版里的部分（照片的圆角用它）。
    static func layer(_ top: CIImage, mask: CIImage?, over below: CIImage) -> CIImage {
        guard let mask else { return top.composited(over: below).cropped(to: below.extent) }
        return top.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: below,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: below.extent)
    }

    static func lanczos(_ image: CIImage, _ scale: CGFloat) -> CIImage {
        image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0,
        ])
    }

    /// 把照片（原点在 0,0）放进 window：大小一样就只是挪过去；不一样就等比铺满、居中、多出来的裁掉。
    static func place(_ photo: CIImage, filling window: CGRect) -> CIImage {
        let e = photo.extent
        if abs(e.width - window.width) < 0.5, abs(e.height - window.height) < 0.5 {
            return photo.transformed(by: CGAffineTransform(translationX: window.minX, y: window.minY))
        }
        let f = max(window.width / e.width, window.height / e.height)
        let scaled = f < 1 ? lanczos(photo, f) : photo.transformed(by: CGAffineTransform(scaleX: f, y: f))
        let s = scaled.extent
        let tx = (window.midX - s.midX).rounded(), ty = (window.midY - s.midY).rounded()
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty)).cropped(to: window)
    }

    /// 圆角矩形的柔和投影。阴影本来就是糊的，所以在缩小的图上做再放大：
    /// 60MP 的图也不慢，而且预览和导出的形状完全一样。
    static func shadow(of rect: CGRect, radius: CGFloat, blur: CGFloat, alpha: CGFloat,
                       canvas: CGRect, over below: CIImage) -> CIImage {
        guard alpha > 0, blur > 0 else { return below }
        let k = min(1, 420 / max(canvas.width, canvas.height))
        let lw = max(1, (canvas.width * k).rounded()), lh = max(1, (canvas.height * k).rounded())
        let kx = lw / canvas.width, ky = lh / canvas.height
        let low = CGRect(x: 0, y: 0, width: lw, height: lh)
        let r = CGRect(x: rect.minX * kx, y: rect.minY * ky, width: rect.width * kx, height: rect.height * ky)
        guard let mask = roundMask(r, radius: radius * min(kx, ky), canvas: low) else { return below }
        let soft = mask.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(blur * min(kx, ky), 0.3)])
            .cropped(to: low)
            .transformed(by: CGAffineTransform(scaleX: 1 / kx, y: 1 / ky))
            .cropped(to: canvas)
        return paint(.black, alpha: alpha, mask: soft, over: below)
    }

    /// 把一行字画成透明底的图，原点在 (0,0)：高度按 height 来，太长就整体缩小到 maxWidth 以内。
    /// 字是用 CoreText 画在一张小位图上再缩放的，位图高度封顶，所以大图导出时也不会占很多内存。
    static func textImage(_ string: String, font name: String, height: CGFloat, maxWidth: CGFloat,
                          color: FrameColor) -> CIImage? {
        guard !string.isEmpty, height >= 1, maxWidth >= 1 else { return nil }
        let drawHeight = min(max(height, 12), 320)
        let font = CTFontCreateWithName(name as CFString, drawHeight * 0.74, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cg,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pad: CGFloat = 3
        let bw = Int(min(ceil(width) + pad * 2, 8192)), bh = Int(ceil(ascent + descent) + pad * 2)
        guard bw >= 2, bh >= 2,
              let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        var k = height / CGFloat(bh)
        if CGFloat(bw) * k > maxWidth { k = maxWidth / CGFloat(bw) }
        let image = CIImage(cgImage: cg)
        if k < 0.999 { return normalized(lanczos(image, k)) }
        return image.transformed(by: CGAffineTransform(scaleX: k, y: k))
    }
}

// MARK: - 边框

enum FrameStyle: String, CaseIterable, Identifiable, Codable {
    case none, solid, line, double, card, polaroid, film, stamp, magazine

    var id: String { rawValue }

    /// 能不能在边框上写一行字。
    var hasCaption: Bool { self == .polaroid || self == .magazine }
    /// 细线内框本来就画在照片里面，没有"向内 / 向外"之分。
    var canGoInside: Bool { self != .none && self != .line }
    /// 除了边框本身的颜色，还有一层垫在后面的底色。
    var hasBacking: Bool { self == .stamp }
}

/// 边框：给照片加一圈边（白边、拍立得、胶片边……），作为编辑历史里的一步。
/// 所有尺寸都按照片短边的比例算，预览和原图导出的效果一样。
struct FrameParams: Equatable, Codable {
    var style: FrameStyle = .none
    /// 边框（纸）的颜色。
    var color = FrameColor.white
    /// 垫在纸后面的底色（邮票用）。
    var backing = FrameColor(r: 0.80, g: 0.82, b: 0.85)
    /// 粗细，0...1。
    var width: CGFloat = 0.35
    /// 照片的圆角，0...1。
    var radius: CGFloat = 0
    /// false = 边框加在照片外面，画布变大；true = 画布不变，边框往照片里占。
    var inside = false
    /// 拍立得、杂志留白上写的一行字。
    var caption = ""

    var isIdentity: Bool { style == .none }

    func apply(to input: CIImage) -> CIImage {
        guard style != .none else { return input }
        let photo = FrameKit.normalized(input)
        let w = photo.extent.width.rounded(), h = photo.extent.height.rounded()
        guard w >= 8, h >= 8 else { return input }
        let s = min(w, h)
        let b = s * (0.012 + 0.1 * min(max(width, 0), 1))
        let corner = s * 0.16 * min(max(radius, 0), 1)
        let full = CGRect(x: 0, y: 0, width: w, height: h)

        if style == .line {
            // 细线内框：照片不动，往里收一点画一圈细线。
            let inset = s * (0.018 + 0.09 * min(max(width, 0), 1))
            let lineWidth = s * (0.0028 + 0.004 * min(max(width, 0), 1))
            let mask = FrameKit.strokeMask(full.insetBy(dx: inset, dy: inset), radius: corner,
                                           lineWidth: lineWidth, canvas: full)
            return FrameKit.paint(color, mask: mask, over: photo.cropped(to: full))
        }

        // 四边各留多宽。
        var left = b, right = b, top = b, bottom = b
        var outer: CGFloat = 0
        let portrait = h >= w
        switch style {
        case .double:
            left = b * 1.5; right = left; top = left; bottom = left
        case .card:
            left = b * 1.7; right = left; top = left; bottom = left
        case .polaroid:
            bottom = b * 4.2
        case .film:
            // 齿孔在长边那两侧。
            let strip = b * 2.3, end = b * 0.7
            if portrait { left = strip; right = strip; top = end; bottom = end }
            else { top = strip; bottom = strip; left = end; right = end }
        case .stamp:
            outer = b
            left = b * 2.3; right = left; top = left; bottom = left
        case .magazine:
            left = b * 1.3; right = left; top = left; bottom = b * 3.8
        default:
            break
        }
        if inside {
            // 边框再宽，也至少留一半给照片。
            let k = min(1, w * 0.5 / (left + right), h * 0.5 / (top + bottom))
            left *= k; right *= k; top *= k; bottom *= k; outer *= k
        }
        left = max(1, left.rounded()); right = max(1, right.rounded())
        top = max(1, top.rounded()); bottom = max(1, bottom.rounded())

        let canvas: CGRect
        let window: CGRect
        if inside {
            canvas = full
            window = CGRect(x: left, y: bottom, width: w - left - right, height: h - top - bottom)
        } else {
            canvas = CGRect(x: 0, y: 0, width: w + left + right, height: h + top + bottom)
            window = CGRect(x: left, y: bottom, width: w, height: h)
        }
        let placed = FrameKit.place(photo, filling: window)
        let ink = color.contrast
        var photoRadius = corner
        var out = FrameKit.fill(style == .stamp ? backing : color, canvas)

        // 照片下面的东西。
        switch style {
        case .card:
            photoRadius = max(corner, s * 0.035)
            out = FrameKit.shadow(of: window.offsetBy(dx: 0, dy: -left * 0.13), radius: photoRadius,
                                  blur: left * 0.3, alpha: 0.42, canvas: canvas, over: out)
        case .film:
            let strip = portrait ? left : top
            let along = strip * 0.30, across = strip * 0.46, pitch = strip * 0.72, hole = strip * 0.07
            let length = portrait ? canvas.height : canvas.width
            let count = max(1, Int((length - pitch * 0.3) / pitch))
            let start = (length - CGFloat(count - 1) * pitch) / 2
            for side in 0..<2 {
                let mask: CIImage?
                if portrait {
                    let x = side == 0 ? strip / 2 : canvas.width - strip / 2
                    mask = FrameKit.holesMask(first: CGPoint(x: x, y: start), step: CGVector(dx: 0, dy: pitch), count: count,
                                              size: CGSize(width: across, height: along), radius: hole, canvas: canvas)
                } else {
                    let y = side == 0 ? strip / 2 : canvas.height - strip / 2
                    mask = FrameKit.holesMask(first: CGPoint(x: start, y: y), step: CGVector(dx: pitch, dy: 0), count: count,
                                              size: CGSize(width: along, height: across), radius: hole, canvas: canvas)
                }
                out = FrameKit.paint(ink, mask: mask, over: out)
            }
        case .stamp:
            let paper = canvas.insetBy(dx: outer, dy: outer)
            out = FrameKit.shadow(of: paper.offsetBy(dx: 0, dy: -outer * 0.14), radius: 0, blur: outer * 0.3,
                                  alpha: 0.32, canvas: canvas, over: out)
            let bite = outer * 0.3
            let nx = max(3, (paper.width / (bite * 3.1)).rounded()), ny = max(3, (paper.height / (bite * 3.1)).rounded())
            let mask = FrameKit.perfMask(paper, pitch: CGSize(width: paper.width / nx, height: paper.height / ny),
                                         radius: bite, canvas: canvas)
            out = FrameKit.paint(color, mask: mask, over: out)
        default:
            break
        }

        // 照片。
        let photoMask = photoRadius > 0 ? FrameKit.roundMask(window, radius: photoRadius, canvas: canvas) : nil
        out = FrameKit.layer(placed, mask: photoMask, over: out)

        // 压在最上面的线和字。
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        switch style {
        case .double:
            let gap = left * 0.42
            let mask = FrameKit.strokeMask(window.insetBy(dx: -gap, dy: -gap),
                                           radius: photoRadius > 0 ? photoRadius + gap : 0,
                                           lineWidth: max(left * 0.075, s * 0.0015), canvas: canvas)
            out = FrameKit.paint(ink, alpha: 0.85, mask: mask, over: out)
        case .polaroid:
            if let label = FrameKit.textImage(text, font: "Noteworthy-Bold", height: bottom * 0.4,
                                              maxWidth: window.width * 0.92, color: ink) {
                let x = (window.midX - label.extent.width / 2).rounded()
                let y = ((bottom - label.extent.height) / 2).rounded()
                out = label.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: out)
            }
        case .magazine:
            if let label = FrameKit.textImage(text, font: "Georgia-Bold", height: bottom * 0.3,
                                              maxWidth: window.width * 0.92, color: ink) {
                let bar = CGRect(x: window.minX, y: (bottom * 0.66).rounded(),
                                 width: (bottom * 0.5).rounded(), height: max(1, (bottom * 0.035).rounded()))
                out = FrameKit.fill(ink, bar).composited(over: out)
                let y = (bottom * 0.56 - label.extent.height).rounded()
                out = label.transformed(by: CGAffineTransform(translationX: window.minX, y: max(y, 0)))
                    .composited(over: out)
            }
        default:
            break
        }
        return out.cropped(to: canvas)
    }
}

/// 边框面板里的一个个样式。点一个就换成它这套默认参数。
struct FramePreset: Identifiable {
    let id: String
    let title: String
    let params: FrameParams

    private static func make(_ id: String, _ title: String, _ style: FrameStyle,
                             _ configure: (inout FrameParams) -> Void = { _ in }) -> FramePreset {
        var p = FrameParams()
        p.style = style
        configure(&p)
        return FramePreset(id: id, title: title, params: p)
    }

    static let all: [FramePreset] = [
        make("none", "无", .none),
        make("white", "白边", .solid),
        make("black", "黑边", .solid) { $0.color = FrameColor(r: 0.04, g: 0.04, b: 0.04) },
        make("line", "细线", .line) { $0.width = 0.3 },
        make("double", "双线", .double) { $0.color = FrameColor(hex: 0xF6F2EA) },
        make("card", "卡片", .card) { $0.color = FrameColor(hex: 0xECEDEF); $0.radius = 0.35 },
        make("polaroid", "拍立得", .polaroid) { $0.color = FrameColor(hex: 0xFBFAF6); $0.width = 0.4 },
        make("film", "胶片", .film) { $0.color = FrameColor(r: 0.05, g: 0.05, b: 0.05); $0.width = 0.3 },
        make("stamp", "邮票", .stamp) { $0.color = FrameColor(hex: 0xFAF8F2); $0.width = 0.3 },
        make("magazine", "杂志", .magazine) { $0.width = 0.4 },
    ]
}

// MARK: - 背景

enum BackdropRatio: String, CaseIterable, Identifiable, Codable {
    case original, r1x1, r3x4, r4x3, r4x5, r9x16, r16x9, r2x3, r3x2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原比例"
        case .r1x1: return "1:1"
        case .r3x4: return "3:4"
        case .r4x3: return "4:3"
        case .r4x5: return "4:5"
        case .r9x16: return "9:16"
        case .r16x9: return "16:9"
        case .r2x3: return "2:3"
        case .r3x2: return "3:2"
        }
    }

    /// 宽 / 高。原比例没有固定值。
    var value: CGFloat? {
        switch self {
        case .original: return nil
        case .r1x1: return 1
        case .r3x4: return 3.0 / 4
        case .r4x3: return 4.0 / 3
        case .r4x5: return 4.0 / 5
        case .r9x16: return 9.0 / 16
        case .r16x9: return 16.0 / 9
        case .r2x3: return 2.0 / 3
        case .r3x2: return 3.0 / 2
        }
    }
}

enum BackdropFill: String, CaseIterable, Identifiable, Codable {
    case blur, solid, gradient, checks, dots, stripes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blur: return "模糊"
        case .solid: return "纯色"
        case .gradient: return "渐变"
        case .checks: return "格子"
        case .dots: return "波点"
        case .stripes: return "条纹"
        }
    }

    var symbol: String {
        switch self {
        case .blur: return "drop"
        case .solid: return "square.fill"
        case .gradient: return "circle.lefthalf.filled"
        case .checks: return "checkerboard.rectangle"
        case .dots: return "circle.grid.3x3"
        case .stripes: return "line.diagonal"
        }
    }

    var isPattern: Bool { self == .checks || self == .dots || self == .stripes }
}

/// 背景：把照片放到一块更大的画布上（指定比例，背景用模糊的照片、纯色、渐变或图案）。
/// 照片保持原来的像素不缩小，是画布按比例变大；所有尺寸都是相对值，预览和导出一样。
struct BackdropParams: Equatable, Codable {
    var ratio: BackdropRatio = .original
    /// 照片在画布里占多大：1 = 刚好顶满，越小四周留得越多。
    var scale: CGFloat = 1
    /// 照片在空出来的地方里的位置，-1...1；x 正 = 往右，y 正 = 往下。
    var offset = CGPoint.zero
    /// 照片的圆角，0...1。
    var radius: CGFloat = 0
    /// 照片的投影，0...1。
    var shadow: CGFloat = 0
    var fill: BackdropFill = .blur
    /// 纯色 / 渐变的第一个颜色 / 图案的底色。
    var colorA = FrameColor.white
    /// 渐变的第二个颜色 / 图案的颜色。
    var colorB = FrameColor(hex: 0xE9E4DA)
    /// 渐变方向（度）：0 = 从左到右，90 = 从上到下。
    var angle: CGFloat = 90
    /// 模糊程度，0...1。
    var blur: CGFloat = 0.55
    /// 模糊背景压暗多少，0...1。
    var dim: CGFloat = 0.2
    /// 图案的大小，0...1。
    var pattern: CGFloat = 0.4

    /// 画布和照片一样大、又没有圆角时，背景一点都露不出来，等于没改。
    var isIdentity: Bool { ratio == .original && scale >= 0.999 && radius <= 0 }

    /// 导出时画布长边最多这么大（照片本身更大就以照片为准，不再往外放）。
    static let maxCanvas: CGFloat = 8192

    /// 照片是 size 这么大时，画布有多大（还没算导出时的封顶）：
    /// 先按比例把照片包住，再按 scale 把画布放大（照片不缩）。
    func canvasSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let aspect = ratio.value ?? size.width / size.height
        var cw = size.width, ch = size.height
        if size.width / size.height > aspect { ch = size.width / aspect } else { cw = size.height * aspect }
        let grow = 1 / min(max(scale, 0.3), 1)
        return CGSize(width: cw * grow, height: ch * grow)
    }

    func apply(to input: CIImage) -> CIImage {
        guard !isIdentity else { return input }
        var photo = FrameKit.normalized(input)
        var w = photo.extent.width.rounded(), h = photo.extent.height.rounded()
        guard w >= 8, h >= 8 else { return input }

        let size = canvasSize(for: CGSize(width: w, height: h))
        var cw = size.width, ch = size.height
        // 太大就整体缩小（照片和画布一起缩，比例关系不变）。
        let long = max(cw, ch)
        if long > Self.maxCanvas {
            let f = Self.maxCanvas / long
            photo = FrameKit.normalized(FrameKit.lanczos(photo, f))
            w = max(1, (w * f).rounded(.down)); h = max(1, (h * f).rounded(.down))
            photo = photo.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            cw *= f; ch *= f
        }
        cw = max(w, cw.rounded()); ch = max(h, ch.rounded())
        let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)
        let short = min(cw, ch)

        // 照片的位置（取整，照片才不会被重新采样变糊）。
        let freeX = cw - w, freeY = ch - h
        let px = (freeX / 2 + min(max(offset.x, -1), 1) * freeX / 2).rounded()
        let py = (freeY / 2 - min(max(offset.y, -1), 1) * freeY / 2).rounded()
        let window = CGRect(x: px, y: py, width: w, height: h)

        // 背景。
        var out: CIImage
        switch fill {
        case .blur:
            out = blurred(photo, canvas: canvas)
        case .solid:
            out = FrameKit.fill(colorA, canvas)
        case .gradient:
            let radians = angle * .pi / 180
            let dir = CGVector(dx: cos(radians), dy: -sin(radians))
            let half = (abs(cw * dir.dx) + abs(ch * dir.dy)) / 2
            out = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: canvas.midX - dir.dx * half, y: canvas.midY - dir.dy * half),
                "inputPoint1": CIVector(x: canvas.midX + dir.dx * half, y: canvas.midY + dir.dy * half),
                "inputColor0": colorA.ci(),
                "inputColor1": colorB.ci(),
            ])?.outputImage?.cropped(to: canvas) ?? FrameKit.fill(colorA, canvas)
        case .checks, .dots, .stripes:
            let cell = short * (0.025 + 0.11 * min(max(pattern, 0), 1))
            let mask: CIImage?
            switch fill {
            case .checks: mask = FrameKit.checksMask(cell: cell, canvas: canvas)
            case .dots: mask = FrameKit.dotsMask(cell: cell, radius: cell * 0.27, canvas: canvas)
            default: mask = FrameKit.stripesMask(period: cell * 1.4, canvas: canvas)
            }
            out = FrameKit.paint(colorB, mask: mask, over: FrameKit.fill(colorA, canvas))
        }

        // 照片的投影和照片。
        let side = min(w, h)
        let corner = side * 0.14 * min(max(radius, 0), 1)
        let depth = min(max(shadow, 0), 1)
        if depth > 0 {
            out = FrameKit.shadow(of: window.offsetBy(dx: 0, dy: -short * 0.012 * depth), radius: corner,
                                  blur: short * (0.008 + 0.03 * depth), alpha: 0.25 + 0.3 * depth,
                                  canvas: canvas, over: out)
        }
        let placed = photo.transformed(by: CGAffineTransform(translationX: px, y: py))
        let mask = corner > 0 ? FrameKit.roundMask(window, radius: corner, canvas: canvas) : nil
        out = FrameKit.layer(placed, mask: mask, over: out)
        return out.cropped(to: canvas)
    }

    /// 模糊背景：照片缩小 → 铺满画布并放大一点 → 模糊、压暗 → 再放大回画布的大小。
    /// 模糊过的图没有细节，在小图上做结果一样，而且原图多大都很快。
    private func blurred(_ photo: CIImage, canvas: CGRect) -> CIImage {
        let k = min(1, 480 / max(canvas.width, canvas.height))
        let lw = max(2, (canvas.width * k).rounded()), lh = max(2, (canvas.height * k).rounded())
        let low = CGRect(x: 0, y: 0, width: lw, height: lh)
        let e = photo.extent
        let f = max(lw / e.width, lh / e.height) * 1.12
        let small = f < 1 ? FrameKit.lanczos(photo, f) : photo.transformed(by: CGAffineTransform(scaleX: f, y: f))
        let s = small.extent
        let centered = small.transformed(by: CGAffineTransform(translationX: low.midX - s.midX, y: low.midY - s.midY))
        let gain = 1 - 0.65 * min(max(dim, 0), 1)
        let soft = centered.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(lw, lh) * (0.012 + 0.07 * min(max(blur, 0), 1)),
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            ])
            .cropped(to: low)
        return soft.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: canvas.width / lw, y: canvas.height / lh))
            .cropped(to: canvas)
    }
}
