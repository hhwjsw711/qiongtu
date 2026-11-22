import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// 固定种子的随机数：同一笔在预览和导出时散布得一模一样。
struct DoodleRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53)
    }

    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        a + (b - a) * unit()
    }

    /// 近似正态分布，标准差 1。
    mutating func gauss() -> CGFloat {
        let u = max(unit(), 1e-9)
        let v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// 把笔画画成位图。只用 Core Graphics / Core Text，所有尺寸都按画布大小折算，
/// 所以 1600 像素的预览和原图分辨率的导出画出来是同一个样子。
enum DoodleRenderer {
    static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    /// 导出时笔画那一层最大画多大（长边像素）。
    static let maxLayerSide: CGFloat = 4096

    // MARK: 画布

    /// 透明的 RGBA 画布，坐标原点在左上角（和图片的归一化坐标同一个方向）。
    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(true)
        return ctx
    }

    static func clear(_ ctx: CGContext) {
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }

    /// 把一张同样大小的位图原样拷进画布（替换掉原来的内容）。
    static func copy(_ image: CGImage, into ctx: CGContext) {
        let h = CGFloat(ctx.height)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(ctx.width), height: h))
        ctx.restoreGState()
    }

    /// 所有笔画（聚光除外）画成一层。
    static func layer(for strokes: [DoodleStroke], width: Int, height: Int) -> CGImage? {
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        let size = CGSize(width: width, height: height)
        for stroke in strokes { draw(stroke, in: ctx, size: size) }
        return ctx.makeImage()
    }

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = 96 * 1024 * 1024
        return c
    }()

    /// 同一份笔画、同一个尺寸只画一遍：撤销重做、放大看细节时会反复用到。内存紧张时系统会自己清掉。
    static func cachedLayer(key: String, strokes: [DoodleStroke], width: Int, height: Int) -> CGImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        guard let image = layer(for: strokes, width: width, height: height) else { return nil }
        cache.setObject(Box(image), forKey: key as NSString, cost: width * height * 4)
        return image
    }

    // MARK: 合成

    /// 聚光：整张压暗，只留出圈住的地方。返回压暗用的那一层（小图，边缘在合成时再柔化）。
    static func dimLayer(spots: [DoodleStroke], size: CGSize) -> CGImage? {
        let k = min(1, 1024 / max(size.width, size.height, 1))
        let w = max(1, Int((size.width * k).rounded()))
        let h = max(1, Int((size.height * k).rounded()))
        var holes: [CGRect] = []
        for s in spots where s.points.count >= 2 {
            let a = s.points[0], b = s.points[s.points.count - 1]
            let r = CGRect(x: min(a.x, b.x) * CGFloat(w), y: min(a.y, b.y) * CGFloat(h),
                           width: abs(a.x - b.x) * CGFloat(w), height: abs(a.y - b.y) * CGFloat(h))
            if r.width >= 3, r.height >= 3 { holes.append(r) }
        }
        guard !holes.isEmpty, let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for r in holes { ctx.fillEllipse(in: r) }
        return ctx.makeImage()
    }

    private static func fitted(_ cg: CGImage, to extent: CGRect) -> CIImage {
        let ci = CIImage(cgImage: cg)
        return ci.transformed(by: CGAffineTransform(scaleX: extent.width / ci.extent.width,
                                                    y: extent.height / ci.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// 把笔画层叠到图上。layers 按顺序从下往上叠，第二项是这一层整体的不透明度。
    static func compose(over image: CIImage, layers: [(CGImage, CGFloat)], spots: [DoodleStroke]) -> CIImage {
        let extent = image.extent
        var out = image
        if !spots.isEmpty, let dim = dimLayer(spots: spots, size: extent.size) {
            let soft = fitted(dim, to: extent)
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(extent.width, extent.height) * 0.012])
                .cropped(to: extent)
            out = soft.composited(over: out)
        }
        for (cg, opacity) in layers {
            var layer = fitted(cg, to: extent)
            if opacity < 0.999 {
                layer = layer.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(opacity, 0)),
                ])
            }
            out = layer.composited(over: out)
        }
        return out.cropped(to: extent)
    }

    // MARK: 几何

    private struct Sample {
        var p: CGPoint
        /// 前进方向（弧度）。
        var angle: CGFloat
        /// 离起点多远（像素）。
        var s: CGFloat
        /// 对应原始点序列里的位置（小数下标）。
        var t: CGFloat
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func length(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<pts.count { total += dist(pts[i - 1], pts[i]) }
        return total
    }

    /// 把手指经过的点连成顺滑的折线：相邻两点的中点之间用二次曲线过渡。
    private static func flatten(_ raw: [CGPoint], step: CGFloat) -> (pts: [CGPoint], t: [CGFloat]) {
        let n = raw.count
        guard n > 2 else { return (raw, raw.indices.map { CGFloat($0) }) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var pts: [CGPoint] = [raw[0]]
        var ts: [CGFloat] = [0]
        var from = mid(raw[0], raw[1])
        pts.append(from)
        ts.append(0.5)
        for i in 1..<(n - 1) {
            let c = raw[i]
            let to = mid(raw[i], raw[i + 1])
            // 细分多少段只看笔的粗细，不看像素数：预览和导出走出来的是同一条折线。
            let k = min(64, max(1, Int(((dist(from, c) + dist(c, to)) / max(step, 0.0001)).rounded(.up))))
            for j in 1...k {
                let u = CGFloat(j) / CGFloat(k)
                let a = (1 - u) * (1 - u), b = 2 * (1 - u) * u, d = u * u
                pts.append(CGPoint(x: a * from.x + b * c.x + d * to.x, y: a * from.y + b * c.y + d * to.y))
                ts.append(CGFloat(i) - 0.5 + u)
            }
            from = to
        }
        pts.append(raw[n - 1])
        ts.append(CGFloat(n - 1))
        return (pts, ts)
    }

    /// 沿折线每隔 spacing 取一个点。
    private static func walk(_ pts: [CGPoint], _ ts: [CGFloat], spacing: CGFloat) -> [Sample] {
        guard let first = pts.first else { return [] }
        guard pts.count > 1 else { return [Sample(p: first, angle: 0, s: 0, t: 0)] }
        let total = length(pts)
        // 笔画特别长、笔又特别细时也不让点数失控。
        let gap = max(spacing, 0.35, total / 30000)
        var out: [Sample] = []
        var next: CGFloat = 0
        var travelled: CGFloat = 0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let d = dist(a, b)
            guard d > 0 else { continue }
            let angle = atan2(b.y - a.y, b.x - a.x)
            while next <= travelled + d {
                let u = (next - travelled) / d
                out.append(Sample(p: CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u), angle: angle,
                                  s: next, t: ts[i - 1] + (ts[i] - ts[i - 1]) * u))
                next += gap
            }
            travelled += d
        }
        if out.isEmpty { out.append(Sample(p: first, angle: 0, s: 0, t: 0)) }
        return out
    }

    /// 折线上离起点 distance 远的那个点。
    private static func point(on pts: [CGPoint], at distance: CGFloat) -> CGPoint {
        guard var last = pts.first else { return .zero }
        var left = max(distance, 0)
        for p in pts.dropFirst() {
            let d = dist(last, p)
            if d > 0, left <= d {
                let u = left / d
                return CGPoint(x: last.x + (p.x - last.x) * u, y: last.y + (p.y - last.y) * u)
            }
            left -= d
            last = p
        }
        return last
    }

    /// 只保留折线的前 keep 这么长。
    private static func trimmed(_ pts: [CGPoint], to keep: CGFloat) -> [CGPoint] {
        guard let first = pts.first else { return [] }
        var out = [first]
        var left = keep
        for p in pts.dropFirst() {
            guard let last = out.last else { break }
            let d = dist(last, p)
            if d >= left {
                if d > 0 {
                    let u = max(left, 0) / d
                    out.append(CGPoint(x: last.x + (p.x - last.x) * u, y: last.y + (p.y - last.y) * u))
                }
                return out
            }
            left -= d
            out.append(p)
        }
        return out
    }

    private static func bounds(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: 一笔

    /// 把一笔画进画布。size = 画布像素尺寸（对应整张图片）。
    static func draw(_ stroke: DoodleStroke, in ctx: CGContext, size: CGSize) {
        let long = max(size.width, size.height)
        guard long > 0, !stroke.points.isEmpty, stroke.brush != .spot else { return }
        let w = max(stroke.width * long, 0.6)
        var raw: [CGPoint] = []
        for p in stroke.points {
            let q = CGPoint(x: p.x * size.width, y: p.y * size.height)
            if let last = raw.last, dist(q, last) < 0.05 { continue }
            raw.append(q)
        }
        guard !raw.isEmpty else { return }

        // 只在这一笔附近画：整笔半透明时要开一个临时图层，范围小才快。
        let reach: CGFloat
        switch stroke.brush {
        case .neon, .number, .arrow, .arrowPen: reach = w * 5 + 4
        default:
            if stroke.brush.category == .pattern {
                // 图案会被散布出去、也会被放大一点：范围按散布算。
                let j = stroke.jitter ?? DoodleJitter()
                reach = w * (1.6 + j.scatter * 1.3) * (stroke.brush == .sparkles ? 2.5 : 1) + 4
            } else {
                reach = w * 1.7 + 4
            }
        }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds(raw).insetBy(dx: -reach, dy: -reach))

        if stroke.brush == .eraser {
            ctx.setBlendMode(.destinationOut)
            strokeLine(ctx, flatten(raw, step: w * 0.1).pts, width: w, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            return
        }
        // 妆容笔：只落在对应的五官上，边缘羽化。范围外一点都不画。
        if !stroke.region.isEmpty {
            guard let (rect, mask) = regionMask(stroke, size: size) else { return }
            ctx.clip(to: rect, mask: mask)
        }
        let opacity = min(max(stroke.opacity, 0), 1)
        let layered = opacity < 0.999
        if layered {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if stroke.brush.isShape {
            shape(stroke, raw: raw, w: w, in: ctx)
        } else {
            freehand(stroke, raw: raw, w: w, long: long, in: ctx)
        }
        if layered { ctx.endTransparencyLayer() }
    }

    private static func strokeLine(_ ctx: CGContext, _ pts: [CGPoint], width: CGFloat, color: CGColor,
                                   cap: CGLineCap = .round, dash: [CGFloat]? = nil, phase: CGFloat = 0) {
        guard let first = pts.first else { return }
        if pts.count == 1 {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            return
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineJoin(.round)
        if let dash { ctx.setLineDash(phase: phase, lengths: dash) }
        ctx.beginPath()
        ctx.addLines(between: pts)
        ctx.strokePath()
        if dash != nil { ctx.setLineDash(phase: 0, lengths: []) }
    }

    private static func fillCircle(_ ctx: CGContext, _ c: CGPoint, radius: CGFloat) {
        ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
    }

    /// 实心箭头尖。tip 是尖端，angle 是指向。
    private static func arrowHead(_ ctx: CGContext, tip: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat, color: CGColor) {
        let ux = cos(angle), uy = sin(angle)
        let back = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        let notch = CGPoint(x: tip.x - ux * length * 0.78, y: tip.y - uy * length * 0.78)
        let left = CGPoint(x: back.x - uy * width / 2, y: back.y + ux * width / 2)
        let right = CGPoint(x: back.x + uy * width / 2, y: back.y - ux * width / 2)
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(width * 0.08, 0.5))
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.beginPath()
        ctx.addLines(between: [tip, left, notch, right])
        ctx.closePath()
        ctx.drawPath(using: .fillStroke)
    }

    private static let maskCache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = 32 * 1024 * 1024
        return c
    }()

    /// 妆容笔范围的灰度蒙版（白 = 能画），只覆盖范围外接矩形那一块。返回画布坐标里的矩形和蒙版。
    private static func regionMask(_ stroke: DoodleStroke, size: CGSize) -> (CGRect, CGImage)? {
        let long = max(size.width, size.height)
        let feather = max(stroke.feather * long, 1)
        let all = stroke.region.flatMap { $0.flatMap { $0 } }.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard !all.isEmpty else { return nil }
        let rect = bounds(all).insetBy(dx: -feather * 2, dy: -feather * 2).integral
            .intersection(CGRect(origin: .zero, size: size))
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let key = "\(stroke.seed)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let hit = maskCache.object(forKey: key) { return (rect, hit.image) }
        let w = Int(rect.width), h = Int(rect.height)
        guard let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // 不翻转坐标：蒙版第 0 行对应范围的最上面，clip 进翻转过的画布时正好对上。
        gray.setFillColor(gray: 1, alpha: 1)
        for shape in stroke.region {
            let path = CGMutablePath()
            for ring in shape where ring.count >= 3 {
                path.addLines(between: ring.map { CGPoint(x: $0.x * size.width - rect.minX, y: $0.y * size.height - rect.minY) })
                path.closeSubpath()
            }
            gray.addPath(path)
            gray.fillPath(using: .evenOdd)
        }
        guard let hard = gray.makeImage() else { return nil }
        let ci = CIImage(cgImage: hard).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        guard let soft = Renderer.shared.context.createCGImage(ci, from: ci.extent, format: .L8,
                                                               colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        maskCache.setObject(Box(soft), forKey: key, cost: w * h)
        return (rect, soft)
    }

    private static func softGradient(_ color: DoodleColor, flow: CGFloat, hardness: CGFloat) -> CGGradient? {
        let h = min(max(hardness, 0), 0.95)
        let colors = [color.cg(flow), color.cg(flow), color.cg(flow * 0.32), color.cg(0)] as CFArray
        return CGGradient(colorsSpace: space, colors: colors, locations: [0, h, h + (1 - h) * 0.5, 1])
    }

    private static func softDab(_ ctx: CGContext, _ gradient: CGGradient, at c: CGPoint, radius: CGFloat) {
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(radius, 0.5), options: [])
    }

    // MARK: 手绘的各种笔

    private static func freehand(_ stroke: DoodleStroke, raw: [CGPoint], w: CGFloat, long: CGFloat, in ctx: CGContext) {
        let color = stroke.color
        let cg = color.cg()
        var rng = DoodleRandom(seed: stroke.seed)
        let line = flatten(raw, step: w * 0.1)
        let pts = line.pts

        switch stroke.brush {
        case .pen:
            strokeLine(ctx, pts, width: w, color: cg)

        case .arrowPen:
            let total = length(pts)
            let headLength = w * 3.6, headWidth = w * 3.3
            guard total > w * 1.2 else {
                strokeLine(ctx, pts, width: w, color: cg)
                return
            }
            // 箭头方向看最后一小段的走向，不看最后两个点，免得手一抖箭头就歪。
            let tip = pts[pts.count - 1]
            let from = point(on: pts, at: max(0, total - max(headLength, w * 4)))
            let angle = atan2(tip.y - from.y, tip.x - from.x)
            strokeLine(ctx, trimmed(pts, to: max(0, total - headLength * 0.7)), width: w, color: cg)
            arrowHead(ctx, tip: tip, angle: angle, length: min(headLength, total), width: headWidth, color: cg)

        case .marker:
            // 斜口笔头：一小段斜线沿着笔迹扫过去，横着粗、斜着细。
            let nx = w * 0.5 * 0.7071, ny = -w * 0.5 * 0.7071
            ctx.setFillColor(cg)
            if pts.count == 1 {
                strokeLine(ctx, [CGPoint(x: pts[0].x - nx, y: pts[0].y - ny), CGPoint(x: pts[0].x + nx, y: pts[0].y + ny)],
                           width: w * 0.3, color: cg, cap: .butt)
                return
            }
            ctx.beginPath()
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                // 四个角按同一个绕向排，重叠的地方才不会被镂空。
                let cross = (b.x - a.x) * ny - (b.y - a.y) * nx
                let quad = [CGPoint(x: a.x - nx, y: a.y - ny), CGPoint(x: a.x + nx, y: a.y + ny),
                            CGPoint(x: b.x + nx, y: b.y + ny), CGPoint(x: b.x - nx, y: b.y - ny)]
                ctx.addLines(between: cross >= 0 ? quad : quad.reversed())
                ctx.closePath()
            }
            ctx.fillPath(using: .winding)
            strokeLine(ctx, pts, width: w * 0.3, color: cg, cap: .butt)

        case .highlighter:
            strokeLine(ctx, pts, width: w, color: cg, cap: .butt)

        case .pencil:
            // 三根错开一点的细线，中间随机断开，像铅笔在纸上蹭出来的。
            guard pts.count > 1 else {
                strokeLine(ctx, pts, width: w * 0.8, color: color.cg(0.8))
                return
            }
            let knots = max(2, Int(length(pts) / (w * 1.6)) + 2)
            for _ in 0..<3 {
                let offsets = (0..<knots).map { _ in rng.range(-0.3, 0.3) * w }
                var moved: [CGPoint] = []
                moved.reserveCapacity(pts.count)
                for i in pts.indices {
                    let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
                    let d = max(dist(a, b), 0.0001)
                    let f = CGFloat(i) / CGFloat(pts.count - 1) * CGFloat(knots - 1)
                    let k = min(Int(f), knots - 2)
                    let o = offsets[k] + (offsets[k + 1] - offsets[k]) * (f - CGFloat(k))
                    moved.append(CGPoint(x: pts[i].x - (b.y - a.y) / d * o, y: pts[i].y + (b.x - a.x) / d * o))
                }
                let dash = [w * rng.range(2, 6), w * rng.range(0.15, 0.5), w * rng.range(1.5, 4), w * rng.range(0.15, 0.4)]
                strokeLine(ctx, moved, width: w * 0.46, color: color.cg(0.55), dash: dash, phase: w * rng.range(0, 4))
            }

        case .calligraphy:
            // 划得快就细、慢就粗，起笔收笔带尖。
            var factor = [CGFloat](repeating: 1, count: raw.count)
            var smooth: CGFloat = 1
            for i in raw.indices.dropFirst() {
                let f = min(max(1.35 - 0.55 * dist(raw[i], raw[i - 1]) / w, 0.3), 1.2)
                smooth = smooth * 0.65 + f * 0.35
                factor[i] = smooth
            }
            if raw.count > 1 { factor[0] = factor[1] }
            let total = length(pts)
            let head = min(w * 3, total * 0.25), tail = min(w * 4, total * 0.3)
            ctx.setFillColor(cg)
            for s in walk(pts, line.t, spacing: w * 0.12) {
                let i = min(Int(s.t), raw.count - 1), j = min(i + 1, raw.count - 1)
                var f = factor[i] + (factor[j] - factor[i]) * (s.t - CGFloat(i))
                if head > 0, s.s < head { f *= 0.25 + 0.75 * s.s / head }
                if tail > 0, total - s.s < tail { f *= 0.12 + 0.88 * (total - s.s) / tail }
                fillCircle(ctx, s.p, radius: max(w * 0.5 * f, 0.3))
            }

        case .crayon:
            // 先铺一层淡淡的底色，再叠很多顺着笔迹方向的小短线：边上稀、中间密，留着蜡笔那种没涂满的缝。
            strokeLine(ctx, pts, width: w * 0.78, color: color.cg(0.38))
            ctx.setLineCap(.round)
            for s in walk(pts, line.t, spacing: w * 0.11) {
                let ux = cos(s.angle), uy = sin(s.angle)
                for _ in 0..<6 {
                    let across = (rng.unit() + rng.unit() - 1) * 0.5 * w
                    let along = rng.range(-0.15, 0.15) * w
                    let half = rng.range(0.07, 0.2) * w
                    let c = CGPoint(x: s.p.x + ux * along - uy * across, y: s.p.y + uy * along + ux * across)
                    ctx.setStrokeColor(color.cg(rng.range(0.5, 1)))
                    ctx.setLineWidth(max(rng.range(0.08, 0.17) * w, 0.4))
                    ctx.beginPath()
                    ctx.move(to: CGPoint(x: c.x - ux * half, y: c.y - uy * half))
                    ctx.addLine(to: CGPoint(x: c.x + ux * half, y: c.y + uy * half))
                    ctx.strokePath()
                }
            }

        case .cloud:
            guard let gradient = softGradient(color, flow: 0.55, hardness: 0.25) else { return }
            for s in walk(pts, line.t, spacing: w * 0.22) {
                for _ in 0..<2 {
                    let c = CGPoint(x: s.p.x + rng.range(-0.28, 0.28) * w, y: s.p.y + rng.range(-0.28, 0.28) * w)
                    softDab(ctx, gradient, at: c, radius: rng.range(0.3, 0.52) * w)
                }
            }

        case .spray:
            for s in walk(pts, line.t, spacing: w * 0.2) {
                for _ in 0..<14 {
                    let c = CGPoint(x: s.p.x + rng.gauss() * 0.3 * w, y: s.p.y + rng.gauss() * 0.3 * w)
                    ctx.setFillColor(color.cg(rng.range(0.6, 1)))
                    fillCircle(ctx, c, radius: max(rng.range(0.018, 0.045) * w, 0.35))
                }
            }

        case .dashed:
            strokeLine(ctx, pts, width: w, color: cg, dash: [w * 2, w * 2.6])

        case .rainbow:
            // 颜色沿着笔迹转一圈色相；转一圈的长度按图片长边算，换分辨率不会变。
            let start = CGFloat(stroke.seed % 1000) / 1000
            let period = long * 0.3
            let samples = walk(pts, line.t, spacing: max(w * 0.25, 1))
            guard samples.count > 1 else {
                strokeLine(ctx, pts, width: w, color: DoodleColor.hue(start).cg())
                return
            }
            for i in 1..<samples.count {
                strokeLine(ctx, [samples[i - 1].p, samples[i].p], width: w,
                           color: DoodleColor.hue(start + samples[i].s / period).cg())
            }
            if let last = pts.last, let end = samples.last {
                strokeLine(ctx, [end.p, last], width: w, color: DoodleColor.hue(start + end.s / period).cg())
            }

        case .neon:
            // 先画两遍带光晕的彩色线，再在中间压一根发白的芯。
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: w * 1.6, color: cg)
            strokeLine(ctx, pts, width: w, color: cg)
            strokeLine(ctx, pts, width: w * 0.8, color: cg)
            ctx.restoreGState()
            strokeLine(ctx, pts, width: w * 0.45, color: color.mixed(with: .white, 0.8).cg())

        case .eyeliner:
            // 起笔渐粗，收笔拉出一个尖；边缘略带一点晕开，不是硬邦邦的实线。
            let total = length(pts)
            let head = min(w * 4, total * 0.2), tail = min(w * 8, total * 0.35)
            guard let gradient = softGradient(color, flow: 0.45, hardness: 0.55) else { return }
            for s in walk(pts, line.t, spacing: w * 0.1) {
                var f: CGFloat = 1
                if head > 0, s.s < head { f *= 0.2 + 0.8 * s.s / head }
                if tail > 0, total - s.s < tail { f *= 0.06 + 0.94 * (total - s.s) / tail }
                softDab(ctx, gradient, at: s.p, radius: max(w * 0.6 * f, 0.4))
            }

        case .brow, .eyeshadow, .blush, .lip, .glow:
            // 妆容：边缘发虚的小圆点一个个叠上去，像刷子带着粉扫过，不是一条硬边的线。
            let flow: CGFloat, hardness: CGFloat
            switch stroke.brush {
            case .brow: (flow, hardness) = (0.2, 0.12)
            case .eyeshadow: (flow, hardness) = (0.08, 0)
            case .blush: (flow, hardness) = (0.06, 0)
            case .lip: (flow, hardness) = (0.24, 0.3)
            default: (flow, hardness) = (0.07, 0)
            }
            guard let gradient = softGradient(color, flow: flow, hardness: hardness) else { return }
            for s in walk(pts, line.t, spacing: w * 0.15) {
                softDab(ctx, gradient, at: s.p, radius: w * 0.5)
            }

        case .stars, .hearts, .sparkles, .bubbles, .petals, .leaves, .raindrops, .snowflakes, .notes:
            let j = stroke.jitter ?? DoodleJitter()
            let copies = max(1, Int(j.count.rounded()))
            for s in walk(pts, line.t, spacing: w * max(j.spacing, 0.2)) {
                for _ in 0..<copies {
                    // 散布：沿着路线和垂直路线两个方向都随机挪开。
                    let across = rng.range(-1, 1) * j.scatter * w
                    let along = (copies > 1 ? rng.range(-1, 1) : rng.range(-0.3, 0.3)) * j.scatter * w
                    let c = CGPoint(x: s.p.x + cos(s.angle) * along - sin(s.angle) * across,
                                    y: s.p.y + sin(s.angle) * along + cos(s.angle) * across)
                    let scale = 1 - j.size * rng.unit() * 0.75 + j.size * 0.15
                    let spin = rng.range(-1, 1) * .pi * j.angle
                    stamp(stroke.brush, at: c, radius: w * 0.5 * scale, spin: spin, color: color, rng: &rng, in: ctx)
                }
            }

        default:
            strokeLine(ctx, pts, width: w, color: cg)
        }
    }

    /// 图案笔的一个图案。spin = 这一个随机转的角度。
    private static func stamp(_ brush: DoodleBrush, at c: CGPoint, radius: CGFloat, spin: CGFloat, color: DoodleColor,
                              rng: inout DoodleRandom, in ctx: CGContext) {
        let alpha = rng.range(0.85, 1)
        switch brush {
        case .stars:
            ctx.setFillColor(color.cg(alpha))
            ctx.addPath(starPath(center: c, radius: radius, inner: 0.42, points: 5, rotation: spin))
            ctx.fillPath()
        case .hearts:
            ctx.setFillColor(color.cg(alpha))
            ctx.addPath(heartPath(center: c, radius: radius, rotation: spin))
            ctx.fillPath()
        case .sparkles:
            let big = rng.unit() < 0.7
            let r = big ? radius : radius * 0.45
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 0.9, color: color.cg())
            ctx.setFillColor(color.mixed(with: .white, 0.85).cg(alpha))
            ctx.addPath(starPath(center: c, radius: r, inner: 0.2, points: 4, rotation: spin * 0.4))
            ctx.fillPath()
            // 旁边再带一颗小光点。
            let d = CGPoint(x: c.x + rng.range(-0.9, 0.9) * radius, y: c.y + rng.range(-0.9, 0.9) * radius)
            fillCircle(ctx, d, radius: max(radius * rng.range(0.06, 0.14), 0.4))
            ctx.restoreGState()
        case .bubbles:
            ctx.setStrokeColor(color.cg(alpha))
            ctx.setLineWidth(max(radius * 0.13, 0.5))
            ctx.setLineCap(.round)
            ctx.strokeEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            ctx.setFillColor(color.cg(alpha * 0.18))
            fillCircle(ctx, c, radius: radius)
            // 左上角一小段高光。
            ctx.setStrokeColor(DoodleColor.white.cg(alpha * 0.9))
            ctx.beginPath()
            ctx.addArc(center: c, radius: radius * 0.62, startAngle: .pi * 1.05, endAngle: .pi * 1.4, clockwise: false)
            ctx.strokePath()
        case .petals:
            // 樱花花瓣：尖头带一个小缺口，颜色深浅略有不同，根部更深一点。
            let tint = color.mixed(with: .white, rng.range(0, 0.35))
            let path = petalPath(center: c, radius: radius, rotation: spin + rng.range(-0.6, 0.6))
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let colors = [color.mixed(with: DoodleColor(r: 0.85, g: 0.3, b: 0.45), 0.35).cg(alpha), tint.cg(alpha)] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.6]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius * 1.1,
                                       options: [.drawsAfterEndLocation])
            }
            ctx.restoreGState()
        case .leaves:
            let leafColor = color.mixed(with: DoodleColor(r: 0.55, g: 0.2, b: 0.05), rng.range(0, 0.4))
            let rot = spin + rng.range(-0.8, 0.8)
            ctx.setFillColor(leafColor.cg(alpha))
            ctx.addPath(leafPath(center: c, radius: radius, rotation: rot))
            ctx.fillPath()
            // 叶脉。
            ctx.setStrokeColor(leafColor.mixed(with: .black, 0.35).cg(alpha * 0.7))
            ctx.setLineWidth(max(radius * 0.06, 0.4))
            ctx.move(to: CGPoint(x: c.x - cos(rot) * radius * 1.05, y: c.y - sin(rot) * radius * 1.05))
            ctx.addLine(to: CGPoint(x: c.x + cos(rot) * radius * 0.9, y: c.y + sin(rot) * radius * 0.9))
            ctx.strokePath()
        case .raindrops:
            // 水滴：上尖下圆，半透明，左上一点高光。
            let path = dropPath(center: c, radius: radius * 0.8, rotation: spin * 0.3)
            ctx.setFillColor(color.cg(alpha * 0.45))
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(color.mixed(with: .white, 0.5).cg(alpha * 0.9))
            ctx.setLineWidth(max(radius * 0.07, 0.4))
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setFillColor(DoodleColor.white.cg(alpha * 0.85))
            fillCircle(ctx, CGPoint(x: c.x - radius * 0.22, y: c.y + radius * 0.05), radius: max(radius * 0.13, 0.4))
        case .snowflakes:
            // 六个瓣，每瓣带两对小枝。
            ctx.setStrokeColor(color.cg(alpha))
            ctx.setLineWidth(max(radius * 0.1, 0.5))
            ctx.setLineCap(.round)
            for i in 0..<6 {
                let a = spin + CGFloat(i) * .pi / 3
                let tip = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
                ctx.move(to: c)
                ctx.addLine(to: tip)
                for k in [0.45, 0.72] as [CGFloat] {
                    let base = CGPoint(x: c.x + cos(a) * radius * k, y: c.y + sin(a) * radius * k)
                    let twig = radius * (1 - k) * 0.7
                    for side in [-1, 1] as [CGFloat] {
                        let b = a + side * 0.75
                        ctx.move(to: base)
                        ctx.addLine(to: CGPoint(x: base.x + cos(b) * twig, y: base.y + sin(b) * twig))
                    }
                }
            }
            ctx.strokePath()
        case .notes:
            let glyph = ["♪", "♫", "♩", "♬"][Int(rng.unit() * 4) % 4]
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: spin * 0.5)
            drawText(glyph, center: .zero, fontSize: radius * 2.2, color: color.cg(alpha), in: ctx)
            ctx.restoreGState()
        default:
            break
        }
    }

    /// 樱花花瓣：根部窄、尖头宽，尖头中间一个小缺口。
    private static func petalPath(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -1, y: 0))
        path.addCurve(to: CGPoint(x: 0.85, y: -0.55), control1: CGPoint(x: -0.4, y: -0.75), control2: CGPoint(x: 0.4, y: -0.8))
        path.addLine(to: CGPoint(x: 0.7, y: 0))
        path.addLine(to: CGPoint(x: 0.85, y: 0.55))
        path.addCurve(to: CGPoint(x: -1, y: 0), control1: CGPoint(x: 0.4, y: 0.8), control2: CGPoint(x: -0.4, y: 0.75))
        path.closeSubpath()
        var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).scaledBy(x: radius, y: radius)
        return path.copy(using: &t) ?? path
    }

    /// 两头尖的叶子。
    private static func leafPath(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -1.05, y: 0))
        path.addCurve(to: CGPoint(x: 1, y: 0), control1: CGPoint(x: -0.5, y: -0.8), control2: CGPoint(x: 0.5, y: -0.6))
        path.addCurve(to: CGPoint(x: -1.05, y: 0), control1: CGPoint(x: 0.5, y: 0.6), control2: CGPoint(x: -0.5, y: 0.8))
        path.closeSubpath()
        var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).scaledBy(x: radius, y: radius * 0.85)
        return path.copy(using: &t) ?? path
    }

    /// 水滴：尖头朝上（y 朝下的坐标里是 -y）。
    private static func dropPath(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -1.4))
        path.addCurve(to: CGPoint(x: 0, y: 0.9), control1: CGPoint(x: 0.5, y: -0.6), control2: CGPoint(x: 1.2, y: 0.9))
        path.addCurve(to: CGPoint(x: 0, y: -1.4), control1: CGPoint(x: -1.2, y: 0.9), control2: CGPoint(x: -0.5, y: -0.6))
        path.closeSubpath()
        var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).scaledBy(x: radius, y: radius)
        return path.copy(using: &t) ?? path
    }

    private static func starPath(center: CGPoint, radius: CGFloat, inner: CGFloat, points: Int, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<(points * 2) {
            let r = i % 2 == 0 ? radius : radius * inner
            let a = rotation - .pi / 2 + CGFloat(i) * .pi / CGFloat(points)
            let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private static func heartPath(center: CGPoint, radius: CGFloat, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        // 以原点为中心、宽高大约是 2 的爱心（y 朝下）。
        path.move(to: CGPoint(x: 0, y: 0.9))
        path.addCurve(to: CGPoint(x: -1, y: -0.2), control1: CGPoint(x: -0.55, y: 0.55), control2: CGPoint(x: -1, y: 0.2))
        path.addCurve(to: CGPoint(x: 0, y: -0.45), control1: CGPoint(x: -1, y: -0.85), control2: CGPoint(x: -0.25, y: -0.95))
        path.addCurve(to: CGPoint(x: 1, y: -0.2), control1: CGPoint(x: 0.25, y: -0.95), control2: CGPoint(x: 1, y: -0.85))
        path.addCurve(to: CGPoint(x: 0, y: 0.9), control1: CGPoint(x: 1, y: 0.2), control2: CGPoint(x: 0.55, y: 0.55))
        path.closeSubpath()
        var t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation).scaledBy(x: radius, y: radius)
        return path.copy(using: &t) ?? path
    }

    // MARK: 标记的形状

    private static func shape(_ stroke: DoodleStroke, raw: [CGPoint], w: CGFloat, in ctx: CGContext) {
        let color = stroke.color
        let cg = color.cg()
        let a = raw[0], b = raw[raw.count - 1]
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))

        switch stroke.brush {
        case .arrow:
            // 尾巴细、越往箭头越粗的实心箭头。
            let total = dist(a, b)
            guard total > 1 else { return }
            let angle = atan2(b.y - a.y, b.x - a.x)
            let headLength = min(max(w * 4.2, 3), total * 0.6)
            let headWidth = max(headLength * 0.95, w * 2.2)
            let tailHalf = w * 0.2, neckHalf = w * 0.5
            ctx.saveGState()
            ctx.translateBy(x: a.x, y: a.y)
            ctx.rotate(by: angle)
            ctx.setFillColor(cg)
            ctx.setStrokeColor(cg)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(max(w * 0.12, 0.5))
            let neck = total - headLength * 0.86
            ctx.beginPath()
            ctx.addLines(between: [
                CGPoint(x: 0, y: -tailHalf), CGPoint(x: neck, y: -neckHalf),
                CGPoint(x: total - headLength, y: -headWidth / 2), CGPoint(x: total, y: 0),
                CGPoint(x: total - headLength, y: headWidth / 2), CGPoint(x: neck, y: neckHalf),
                CGPoint(x: 0, y: tailHalf),
            ])
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
            fillCircle(ctx, .zero, radius: tailHalf)
            ctx.restoreGState()

        case .line:
            guard dist(a, b) > 0.5 else { return }
            strokeLine(ctx, [a, b], width: w, color: cg)

        case .rect:
            guard box.width > 1 || box.height > 1 else { return }
            let radius = min(w, min(box.width, box.height) / 2)
            ctx.setStrokeColor(cg)
            ctx.setLineWidth(w)
            ctx.setLineJoin(.round)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()

        case .ellipse:
            guard box.width > 1 || box.height > 1 else { return }
            ctx.setStrokeColor(cg)
            ctx.setLineWidth(w)
            ctx.strokeEllipse(in: box)

        case .bar:
            guard box.width > 1, box.height > 1 else { return }
            let radius = min(w * 0.8, min(box.width, box.height) / 2)
            ctx.setFillColor(cg)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()

        case .number:
            let radius = w * 2.4
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: radius * 0.3, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.4))
            ctx.setFillColor(cg)
            fillCircle(ctx, b, radius: radius)
            ctx.restoreGState()
            let ink: DoodleColor = color.isLight ? DoodleColor(r: 0.1, g: 0.1, b: 0.1) : .white
            ctx.setStrokeColor(ink.cg(0.95))
            ctx.setLineWidth(radius * 0.13)
            let ring = radius * 0.84
            ctx.strokeEllipse(in: CGRect(x: b.x - ring, y: b.y - ring, width: ring * 2, height: ring * 2))
            let text = "\(stroke.number)"
            let fontSize = radius * (text.count <= 1 ? 1.2 : text.count == 2 ? 0.95 : 0.72)
            drawText(text, center: b, fontSize: fontSize, color: ink.cg(), in: ctx)

        default:
            break
        }
    }

    private static func drawText(_ text: String, center: CGPoint, fontSize: CGFloat, color: CGColor, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.saveGState()
        // 画布是上下翻过来的，文字要翻回去才是正的。
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -box.midX, y: -box.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: 画笔缩略图

    /// 画笔列表上的示意图：用这支笔画一条波浪线。
    static func sample(_ brush: DoodleBrush, width: Int, height: Int) -> CGImage? {
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        var points: [CGPoint] = []
        for i in 0...30 {
            let u = CGFloat(i) / 30
            points.append(CGPoint(x: 0.13 + 0.74 * u,
                                  y: 0.52 - 0.3 * sin(u * .pi * 3 + 0.4) * (1 - 0.3 * u) + 0.06 * (u - 0.5)))
        }
        let base: CGFloat = 0.05
        let stroke = DoodleStroke(brush: brush, points: points, width: min(base * brush.widthFactor, 0.34),
                                  color: brush.sampleColor, opacity: max(brush.defaultOpacity, 0.85), seed: 20261122)
        draw(stroke, in: ctx, size: CGSize(width: width, height: height))
        return ctx.makeImage()
    }
}
