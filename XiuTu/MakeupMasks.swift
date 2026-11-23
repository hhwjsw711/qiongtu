import CoreGraphics
import Foundation

/// 美妆要画的每一种形状。每种形状画成一张灰度蒙版（白 = 上妆的地方），
/// 颜色和浓淡之后交给 Core Image 处理，所以拖滑块时蒙版不用重画。
enum MKShape: Hashable {
    case lipFull, lipGradient, lipLine, lipGloss(Bool)
    case blush(MKBlushPlacement), blushGlow(MKBlushPlacement)
    case browFill(MKBrowShape), browHair(MKBrowShape)
    case shadowLid, shadowCrease, shadowOuter, shadowLower, shadowSmoke, shimmer, sparkle
    case liner(MKLinerStyle), lashes(MKLashStyle), fold(MKFoldStyle)
    case aegyoLight, aegyoShade
    case lens, lensRing, lensRays, catchlight(MKCatchlight)
    case noseShade, noseLight, hlForehead, hlCheek, hlChin, hlCupid, hlUnderEye
    case shJaw, shCheek, shTemple
    case freckles(MKFreckleStyle)
    case moles([MKMoleSpot])

    /// 蒙版位图的边长：越柔的形状用越小的图。fine 是精细形状（睫毛、眼线）用的边长。
    func raster(fine: Int) -> Int {
        switch self {
        case .blush, .blushGlow, .hlForehead, .hlCheek, .hlChin, .hlUnderEye, .shJaw, .shCheek, .shTemple,
             .noseShade, .noseLight, .shadowCrease, .aegyoLight, .aegyoShade:
            return 256
        case .lipFull, .lipGradient, .lipGloss, .shadowLid, .shadowOuter, .shadowLower, .shadowSmoke, .shimmer,
             .browFill, .lens, .hlCupid:
            return 512
        default:
            return fine
        }
    }
}

/// 固定种子的随机数：睫毛、雀斑这类"随机"的形状，预览和导出必须长得一样。
struct MKRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> CGFloat {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(1 << 53)
    }

    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }

    /// 近似正态分布（-1...1 之间居多）。
    mutating func gauss() -> CGFloat { (next() + next() + next() + next() - 2) / 1.15 }
}

/// 在一张灰度位图上画蒙版。坐标用这张脸方框里的 0...1（原点左上角，y 朝下）。
final class MKPainter {
    let ctx: CGContext
    let size: Int
    private static let gray = CGColorSpaceCreateDeviceGray()

    init?(size: Int) {
        guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: Self.gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx = c
        self.size = size
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: CGFloat(size), y: -CGFloat(size))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setShouldAntialias(true)
    }

    func image() -> CGImage? { ctx.makeImage() }

    // MARK: 路径

    /// 穿过各点的平滑闭合曲线。
    static func smoothClosed(_ points: [MKVec], perSegment: Int = 6) -> [MKVec] {
        let n = points.count
        guard n >= 3 else { return points }
        var out: [MKVec] = []
        for i in 0..<n {
            let p0 = points[(i + n - 1) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            for s in 0..<perSegment {
                let t = CGFloat(s) / CGFloat(perSegment)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                    + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                    + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                out.append(MKVec(x, y))
            }
        }
        return out
    }

    /// 二次贝塞尔曲线上均匀取几个点。
    static func bezier(_ a: MKVec, _ control: MKVec, _ b: MKVec, samples: Int = 8) -> [MKVec] {
        (0...samples).map { i in
            let t = CGFloat(i) / CGFloat(samples), u = 1 - t
            return a * (u * u) + control * (2 * u * t) + b * (t * t)
        }
    }

    static func polygon(_ points: [MKVec], closed: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first.cg)
        for p in points.dropFirst() { path.addLine(to: p.cg) }
        if closed { path.closeSubpath() }
        return path
    }

    func fill(_ points: [MKVec], gray: CGFloat = 1, alpha: CGFloat = 1) {
        guard points.count >= 3 else { return }
        ctx.setFillColor(gray: gray, alpha: alpha)
        ctx.addPath(Self.polygon(points))
        ctx.fillPath()
    }

    func stroke(_ points: [MKVec], width: CGFloat, gray: CGFloat = 1, alpha: CGFloat = 1, closed: Bool = false) {
        guard points.count >= 2, width > 0 else { return }
        ctx.setStrokeColor(gray: gray, alpha: alpha)
        ctx.setLineWidth(width)
        ctx.addPath(Self.polygon(points, closed: closed))
        ctx.strokePath()
    }

    func dot(_ center: MKVec, radius: CGFloat, gray: CGFloat = 1, alpha: CGFloat = 1) {
        ctx.setFillColor(gray: gray, alpha: alpha)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// 一条两头尖的线：沿 points 走，中间粗 half、两端收到 0。taperStart/taperEnd 是各自收尖占的比例。
    func tapered(_ points: [MKVec], half: (CGFloat) -> CGFloat, alpha: CGFloat = 1) {
        guard points.count >= 2 else { return }
        var left: [MKVec] = [], right: [MKVec] = []
        let n = points.count
        for i in 0..<n {
            let a = points[max(i - 1, 0)], b = points[min(i + 1, n - 1)]
            let normal = (b - a).unit.perp
            let h = half(CGFloat(i) / CGFloat(n - 1))
            left.append(points[i] + normal * h)
            right.append(points[i] - normal * h)
        }
        fill(left + right.reversed(), alpha: alpha)
    }

    /// 高斯状的柔和椭圆：中心最亮，往外渐隐。axis 是长轴方向。
    func blob(_ center: MKVec, rx: CGFloat, ry: CGFloat, axis: MKVec = MKVec(1, 0), alpha: CGFloat = 1) {
        guard rx > 0, ry > 0 else { return }
        let stops: [CGFloat] = [0, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1]
        let values: [CGFloat] = [1, 0.93, 0.76, 0.54, 0.33, 0.16, 0.045, 0]
        var components: [CGFloat] = []
        for v in values { components += [1, v * alpha] }
        guard let gradient = CGGradient(colorSpace: Self.gray, colorComponents: components, locations: stops,
                                        count: stops.count) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: atan2(axis.y, axis.x))
        ctx.scaleBy(x: rx, y: ry)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
        ctx.restoreGState()
    }

    /// 环形渐变：stops 是 (半径比例, 亮度)。
    func ring(_ center: MKVec, radius: CGFloat, stops: [(CGFloat, CGFloat)]) {
        var components: [CGFloat] = []
        for s in stops { components += [1, s.1] }
        guard let gradient = CGGradient(colorSpace: Self.gray, colorComponents: components,
                                        locations: stops.map(\.0), count: stops.count) else { return }
        ctx.drawRadialGradient(gradient, startCenter: center.cg, startRadius: 0, endCenter: center.cg,
                               endRadius: radius, options: [])
    }

    func clipped(to points: [MKVec], _ body: () -> Void) {
        guard points.count >= 3 else { return }
        ctx.saveGState()
        ctx.addPath(Self.polygon(points))
        ctx.clip()
        body()
        ctx.restoreGState()
    }
}

// MARK: - 各种形状的画法

extension MKFace {
    /// 这张脸对应某个形状的蒙版。画不出来（比如缺关键点）返回 nil。
    func drawMask(_ shape: MKShape, size: Int, imageSize: CGSize) -> CGImage? {
        guard let p = MKPainter(size: size) else { return nil }
        switch shape {
        case .lipFull: drawLips(p, gradient: false)
        case .lipGradient: drawLips(p, gradient: true)
        case .lipLine: p.stroke(lipPath, width: mouthWidth * 0.016, closed: true)
        case .lipGloss(let strong): drawLipGloss(p, strong: strong)
        case .blush(let placement): drawBlush(p, placement, glow: false)
        case .blushGlow(let placement): drawBlush(p, placement, glow: true)
        case .browFill(let s): drawBrows(p, s, hair: false)
        case .browHair(let s): drawBrows(p, s, hair: true)
        case .shadowLid: for e in eyes { drawLidZone(p, e, height: min(0.40 * e.width, 0.5 * e.browGap), spread: 0.10) }
        case .shadowCrease: for e in eyes { drawLidZone(p, e, height: min(0.78 * e.width, 0.84 * e.browGap), spread: 0.20) }
        case .shadowOuter:
            for e in eyes {
                p.blob(e.outer + e.axis * (e.width * 0.07) + e.up * (e.width * 0.11), rx: e.width * 0.32, ry: e.width * 0.17,
                       axis: (e.axis * 0.8 + e.up * 0.55).unit)
            }
        case .shadowLower: for e in eyes { drawLowerBand(p, e) }
        case .shadowSmoke: for e in eyes { p.stroke(e.outline, width: e.width * 0.17, closed: true) }
        case .shimmer:
            for e in eyes {
                p.blob(e.upper.at(0.5) + e.up * (e.width * 0.075), rx: e.width * 0.25, ry: e.width * 0.075, axis: e.axis)
            }
        case .sparkle: drawSparkle(p)
        case .liner(let style): for (i, e) in eyes.enumerated() { drawLiner(p, e, style, index: i) }
        case .lashes(let style): for (i, e) in eyes.enumerated() { drawLashes(p, e, style, index: i) }
        case .fold(let style): for e in eyes { drawFold(p, e, style) }
        case .aegyoLight:
            for e in eyes {
                var top: [MKVec] = [], bottom: [MKVec] = []
                for s in 0...12 {
                    let t = 0.08 + 0.84 * CGFloat(s) / 12
                    let base = e.lower.at(t) - e.up * (e.width * 0.015)
                    top.append(base)
                    bottom.append(base - e.up * (e.width * 0.085 * pow(sin(CGFloat.pi * CGFloat(s) / 12), 0.7)))
                }
                p.fill(top + bottom.reversed())
            }
        case .aegyoShade:
            for e in eyes {
                var line: [MKVec] = []
                for s in 0...12 {
                    let f = CGFloat(s) / 12
                    line.append(e.lower.at(0.12 + 0.76 * f) - e.up * (e.width * (0.012 + 0.125 * pow(sin(.pi * f), 0.6))))
                }
                p.tapered(line, half: { e.width * 0.014 * sin(.pi * $0) })
            }
        case .lens:
            for e in eyes {
                p.clipped(to: e.outline) {
                    p.ring(e.center, radius: irisRadius(e), stops: [(0, 0), (0.30, 0), (0.50, 1), (0.90, 1), (1, 0)])
                }
            }
        case .lensRing:
            for e in eyes {
                p.clipped(to: e.outline) {
                    p.ring(e.center, radius: irisRadius(e) * 1.04, stops: [(0, 0), (0.76, 0), (0.90, 1), (0.97, 0.7), (1, 0)])
                }
            }
        case .lensRays:
            for (i, e) in eyes.enumerated() {
                var random = MKRandom(seed: 0x1E45 + UInt64(i))
                let r = irisRadius(e)
                p.clipped(to: e.outline) {
                    for k in 0..<46 {
                        let angle = (CGFloat(k) + random.range(-0.3, 0.3)) / 46 * 2 * .pi
                        let dir = MKVec(cos(angle), sin(angle))
                        p.stroke([e.center + dir * (r * random.range(0.40, 0.5)), e.center + dir * (r * random.range(0.72, 0.9))],
                                 width: r * 0.035, alpha: random.range(0.35, 1))
                    }
                }
            }
        case .catchlight(let style): for e in eyes { drawCatchlight(p, e, style) }
        case .noseShade: drawNose(p, light: false)
        case .noseLight: drawNose(p, light: true)
        case .hlForehead:
            p.blob(eyeMid + up * (eyeDist * 0.80), rx: eyeDist * 0.42, ry: eyeDist * 0.25, axis: right)
        case .hlCheek:
            for (i, e) in eyes.enumerated() where e.visible {
                let outward = i == 0 ? -right : right
                p.blob(e.outer.lerp(e.center, 0.4) + down * (mouthDist * 0.38), rx: eyeDist * 0.32, ry: eyeDist * 0.18,
                       axis: (outward * 0.9 + up * 0.38).unit)
            }
        case .hlChin:
            p.blob(lipBottom.lerp(chin, 0.5), rx: eyeDist * 0.19, ry: eyeDist * 0.13, axis: right)
        case .hlCupid:
            p.blob(lipTop + up * (eyeDist * 0.045), rx: eyeDist * 0.075, ry: eyeDist * 0.036, axis: right)
        case .hlUnderEye:
            for (i, e) in eyes.enumerated() {
                let inward = i == 0 ? right : -right
                p.blob(e.center + down * (eyeDist * 0.33) + inward * (eyeDist * 0.05), rx: eyeDist * 0.24, ry: eyeDist * 0.14,
                       axis: (inward * 0.9 - down * 0.35).unit, alpha: e.visible ? 1 : 0.6)
            }
        case .shJaw:
            let center = noseBase
            var line: [MKVec] = []
            for s in 0...28 {
                let point = contour.at(0.10 + 0.80 * CGFloat(s) / 28)
                line.append(point + (center - point).unit * (faceWidth * 0.03))
            }
            p.stroke(line, width: faceWidth * 0.08)
        case .shCheek:
            // 轮廓线的哪一头靠着哪只眼睛。
            let startIsLeft = contour.at(0).dist(eyes[0].center) < contour.at(0).dist(eyes[1].center)
            for (i, e) in eyes.enumerated() where e.visible {
                let t: CGFloat = (i == 0) == startIsLeft ? 0.13 : 0.87
                let start = contour.at(t)
                let corner = mouthCenter + (i == 0 ? -right : right) * (mouthWidth * 0.5) + up * (eyeDist * 0.06)
                let inset = start + (corner - start).unit * (faceWidth * 0.035)
                p.stroke([inset, inset.lerp(corner, 0.52)], width: faceWidth * 0.065)
            }
        case .shTemple:
            for (i, e) in eyes.enumerated() where e.visible {
                let outward = i == 0 ? -right : right
                let anchor = brows[i]?.center.at(1) ?? (e.outer + up * (eyeDist * 0.3))
                p.blob(anchor + up * (eyeDist * 0.24) + outward * (eyeDist * 0.12), rx: eyeDist * 0.26, ry: eyeDist * 0.14,
                       axis: up)
            }
        case .freckles(let style): drawFreckles(p, style)
        case .moles(let spots): drawMoles(p, spots, imageSize: imageSize)
        }
        return p.image()
    }

    var lipPath: [MKVec] { MKPainter.smoothClosed(lipsOuter, perSegment: 5) }

    /// 张着嘴时，嘴里面（牙齿）不上色。闭着嘴时内唇线几乎是一条线，就不用挖了。
    private var mouthOpening: [MKVec]? {
        guard lipsInner.count >= 3 else { return nil }
        var area: CGFloat = 0
        for i in 0..<lipsInner.count {
            let a = lipsInner[i], b = lipsInner[(i + 1) % lipsInner.count]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) / 2 > mouthWidth * mouthWidth * 0.012 ? lipsInner : nil
    }

    func irisRadius(_ eye: MKEye) -> CGFloat { eye.width * 0.235 }

    private func drawLips(_ p: MKPainter, gradient: Bool) {
        let path = lipPath
        if gradient {
            // 咬唇：中间浓、往唇边淡下去。
            p.fill(path, alpha: 0.22)
            let height = max(lipTop.dist(lipBottom), mouthWidth * 0.2)
            p.clipped(to: path) {
                p.blob(mouthCenter, rx: mouthWidth * 0.46, ry: height * 0.62, axis: right)
            }
        } else {
            p.fill(path)
        }
        if let opening = mouthOpening { p.fill(opening, gray: 0) }
    }

    private func drawLipGloss(_ p: MKPainter, strong: Bool) {
        let lower = max(mouthCenter.dist(lipBottom), mouthWidth * 0.08)
        let upper = max(mouthCenter.dist(lipTop), mouthWidth * 0.06)
        p.clipped(to: lipPath) {
            p.blob(mouthCenter.lerp(lipBottom, 0.52), rx: mouthWidth * 0.20, ry: lower * 0.20, axis: right, alpha: 0.85)
            for sign: CGFloat in [-1, 1] {
                p.blob(lipTop.lerp(mouthCenter, 0.38) + right * (mouthWidth * 0.13 * sign), rx: mouthWidth * 0.07,
                       ry: upper * 0.16, axis: right, alpha: 0.55)
            }
            if strong {
                p.blob(mouthCenter.lerp(lipBottom, 0.44), rx: mouthWidth * 0.12, ry: lower * 0.075, axis: right)
                p.blob(mouthCenter.lerp(lipBottom, 0.50) + right * (mouthWidth * 0.2), rx: mouthWidth * 0.04,
                       ry: lower * 0.06, axis: right, alpha: 0.7)
            }
        }
        if let opening = mouthOpening { p.fill(opening, gray: 0) }
    }

    private func drawBlush(_ p: MKPainter, _ placement: MKBlushPlacement, glow: Bool) {
        for (i, e) in eyes.enumerated() where e.visible {
            let outward = i == 0 ? -right : right
            let m = mouthDist, s = e.side
            if glow {
                // 光泽感：颧骨最高处一小块亮。
                p.blob(e.center + down * (m * 0.34) + outward * (s * 0.22), rx: s * 0.26, ry: s * 0.11,
                       axis: (outward * 0.9 + up * 0.4).unit, alpha: 0.9)
                continue
            }
            switch placement {
            case .apple:
                p.blob(e.center + down * (m * 0.54) + outward * (s * 0.16), rx: s * 0.66, ry: s * 0.52, axis: right)
            case .sweep:
                p.blob(e.center + down * (m * 0.47) + outward * (s * 0.36), rx: s * 0.74, ry: s * 0.34,
                       axis: (outward * 0.86 + up * 0.5).unit)
            case .underEye:
                p.blob(e.center + down * (m * 0.35) + outward * (s * 0.08), rx: s * 0.68, ry: s * 0.27, axis: right)
            case .sunburn:
                p.blob(e.center + down * (m * 0.36) + outward * (s * 0.05), rx: s * 0.68, ry: s * 0.28, axis: right)
            case .high:
                p.blob(e.center + down * (m * 0.30) + outward * (s * 0.36), rx: s * 0.56, ry: s * 0.30,
                       axis: (outward * 0.75 + up * 0.66).unit)
            case .doll:
                p.blob(e.center + down * (m * 0.56) + outward * (s * 0.08), rx: s * 0.42, ry: s * 0.38, axis: right)
            case .drunk:
                p.blob(e.center + down * (m * 0.44) + outward * (s * 0.02), rx: s * 0.72, ry: s * 0.40, axis: right)
            }
        }
        guard !glow else { return }
        if placement == .sunburn {
            p.blob(ridge.at(0.62), rx: eyeDist * 0.46, ry: mouthDist * 0.15, axis: right, alpha: 0.9)
        }
        if placement == .drunk {
            p.blob(noseTip, rx: eyeDist * 0.16, ry: eyeDist * 0.13, axis: right, alpha: 0.7)
        }
    }

    // MARK: 眉毛

    /// 按眉形算出要画的中线和半宽（各 17 个点，从眉头到眉尾）。
    private func browTarget(_ brow: MKBrow, _ shape: MKBrowShape) -> (center: [MKVec], half: [CGFloat]) {
        let l = brow.length
        var extend: CGFloat = 0.04
        switch shape {
        case .natural, .soft: extend = 0.04
        case .straight: extend = 0.03
        case .wild: extend = 0.02
        case .droop: extend = 0.10
        case .willow: extend = 0.12
        case .sword: extend = 0
        case .arch: extend = 0.05
        }
        func original(_ t: CGFloat) -> MKVec {
            t <= 1 ? brow.center.at(t) : brow.center.at(1) + brow.center.tangent(1) * ((t - 1) * l)
        }
        func envelope(_ t: CGFloat, head: CGFloat, tail: CGFloat, hold: CGFloat) -> CGFloat {
            let rise = head + (1 - head) * mkSmoothstep(0, 0.25, t)
            return rise * (1 - (1 - tail) * mkSmoothstep(hold, 1, t))
        }
        var center: [MKVec] = [], half: [CGFloat] = []
        let count = 16
        for s in 0...count {
            let f = CGFloat(s) / CGFloat(count)          // 0...1 画出来的眉毛
            let t = f * (1 + extend)                     // 对应原眉毛的位置
            let natural = max(brow.thickness(at: min(t, 1)), l * 0.11)
            var c = original(t)
            var width: CGFloat
            switch shape {
            case .natural:
                width = natural * envelope(f, head: 0.78, tail: 0.2, hold: 0.5)
            case .soft:
                width = natural * 1.1 * envelope(f, head: 0.8, tail: 0.3, hold: 0.5)
            case .wild:
                width = natural * 1.28 * envelope(f, head: 0.95, tail: 0.22, hold: 0.55)
            case .straight:
                let line = original(0).lerp(original(1 + extend) + brow.up * (l * 0.04), f)
                c = c.lerp(line, 0.7)
                width = l * 0.105 * envelope(f, head: 0.9, tail: 0.35, hold: 0.68)
            case .droop:
                c = c - brow.up * (l * 0.085 * mkSmoothstep(0.5, 1.05, f))
                width = natural * 0.95 * envelope(f, head: 0.78, tail: 0.16, hold: 0.45)
            case .willow:
                c = c + brow.up * (l * 0.03 * sin(.pi * f))
                width = l * 0.064 * envelope(f, head: 0.7, tail: 0.14, hold: 0.4)
            case .sword:
                let head = original(0) - brow.up * (l * 0.02)
                let peak = original(0.72) + brow.up * (l * 0.05)
                let end = original(1) + brow.up * (l * 0.005)
                c = f <= 0.72 ? head.lerp(peak, f / 0.72) : peak.lerp(end, (f - 0.72) / 0.28)
                width = l * 0.118 * envelope(f, head: 1, tail: 0.1, hold: 0.7)
            case .arch:
                let bump = exp(-pow((f - 0.66) / 0.2, 2))
                c = c + brow.up * (l * 0.06 * bump)
                width = l * 0.092 * envelope(f, head: 0.85, tail: 0.12, hold: 0.55)
            }
            center.append(c)
            half.append(width / 2)
        }
        return (center, half)
    }

    private func drawBrows(_ p: MKPainter, _ shape: MKBrowShape, hair: Bool) {
        for (index, brow) in brows.enumerated() {
            guard let brow else { continue }
            let target = browTarget(brow, shape)
            let n = target.center.count
            func normal(_ i: Int) -> MKVec {
                let tangent = (target.center[min(i + 1, n - 1)] - target.center[max(i - 1, 0)]).unit
                var v = tangent.perp
                if v.dot(brow.up) < 0 { v = -v }
                return v
            }
            if !hair {
                var top: [MKVec] = [], bottom: [MKVec] = []
                for i in 0..<n {
                    top.append(target.center[i] + normal(i) * target.half[i])
                    bottom.append(target.center[i] - normal(i) * target.half[i])
                }
                p.fill(top + bottom.reversed())
                continue
            }
            // 一根根的眉毛：眉头的往上长，越往眉尾越顺着眉毛的方向倒。
            var random = MKRandom(seed: 0xB20 + UInt64(index) &* 31 &+ UInt64(shape.rawValue))
            let count = shape == .wild ? 64 : (shape == .willow ? 34 : 48)
            for k in 0..<count {
                let f = min(max((CGFloat(k) + random.range(-0.4, 0.4)) / CGFloat(count), 0), 1) * 0.9
                let position = f * CGFloat(n - 1)
                let i = min(Int(position), n - 2)
                let c = target.center[i].lerp(target.center[i + 1], position - CGFloat(i))
                let h = target.half[i] + (target.half[i + 1] - target.half[i]) * (position - CGFloat(i))
                let nrm = normal(i)
                let along = (target.center[i + 1] - target.center[i]).unit
                let lean = mkSmoothstep(0, 0.75, f)
                var direction = (nrm * (1 - 0.9 * lean) + along * (0.3 + 0.75 * lean)).unit
                if shape == .wild { direction = (direction + nrm * (0.5 * (1 - lean))).unit }
                let base = c - nrm * (h * random.range(0.15, 0.95))
                let length = h * random.range(1.2, shape == .wild ? 2.5 : 1.8)
                guard length > brow.length * 0.012 else { continue }
                let tip = base + direction * length
                p.tapered(MKPainter.bezier(base, base.lerp(tip, 0.5) + along * (length * 0.14), tip, samples: 5),
                          half: { brow.length * 0.0045 * (1 - 0.85 * $0) }, alpha: random.range(0.5, 1))
            }
        }
    }

    // MARK: 眼妆

    /// 上眼睑往上的一片区域：height 是最高处离眼睑多远，spread 是往眼尾外面延伸多少（按眼宽）。
    private func drawLidZone(_ p: MKPainter, _ e: MKEye, height: CGFloat, spread: CGFloat) {
        var bottom: [MKVec] = [], top: [MKVec] = []
        for s in 0...14 {
            let t = CGFloat(s) / 14
            let lid = e.upper.at(t)
            bottom.append(lid)
            let profile = 0.4 + 0.6 * pow(sin(.pi * (0.12 + 0.76 * t)), 0.8)
            top.append(lid + e.up * (height * profile) + e.axis * (e.width * spread * t * t))
        }
        let wing = e.outer + e.axis * (e.width * (spread + 0.03)) + e.up * (e.width * 0.04)
        p.fill(bottom + [wing] + top.reversed())
    }

    private func drawLowerBand(_ p: MKPainter, _ e: MKEye) {
        var top: [MKVec] = [], bottom: [MKVec] = []
        for s in 0...10 {
            let t = 0.3 + 0.7 * CGFloat(s) / 10
            let lid = e.lower.at(t)
            top.append(lid)
            bottom.append(lid - e.up * (e.width * 0.085 * mkSmoothstep(0.25, 0.9, t)))
        }
        p.fill(top + [e.outer + e.axis * (e.width * 0.06)] + bottom.reversed())
    }

    private func drawSparkle(_ p: MKPainter) {
        for (i, e) in eyes.enumerated() {
            var random = MKRandom(seed: 0x5A2 + UInt64(i))
            let center = e.upper.at(0.55) + e.up * (e.width * 0.05)
            for k in 0..<26 {
                let angle = random.range(0, 2 * .pi), r = sqrt(random.next())
                let point = center + e.axis * (cos(angle) * r * e.width * 0.34) + e.up * (sin(angle) * r * e.width * 0.035)
                let size = e.width * random.range(0.005, 0.011)
                p.dot(point, radius: size, alpha: random.range(0.5, 1))
                if k % 7 == 0 {
                    // 每隔几颗画一个十字星芒。
                    p.stroke([point - e.axis * (size * 3.2), point + e.axis * (size * 3.2)], width: size * 0.5, alpha: 0.9)
                    p.stroke([point - e.up * (size * 3.2), point + e.up * (size * 3.2)], width: size * 0.5, alpha: 0.9)
                }
            }
        }
    }

    private func drawLiner(_ p: MKPainter, _ e: MKEye, _ style: MKLinerStyle, index: Int) {
        let w = e.width
        var thickStart: CGFloat = 0.006, thickEnd: CGFloat = 0.028
        // 翘尾的尖在眼尾外面多远（沿眼睛方向）、比眼尾高多少，都按眼宽算。nil = 不翘。
        var wing: (out: CGFloat, rise: CGFloat)?
        switch style {
        case .thin:
            thickStart = 0.004; thickEnd = 0.016
        case .natural:
            wing = (0.09, 0.06)
        case .wing:
            wing = (0.17, 0.13)
        case .puppy:
            wing = (0.14, -0.035)
        case .cat:
            thickEnd = 0.040
            wing = (0.26, 0.20)
        case .full:
            thickEnd = 0.034
            wing = (0.15, 0.10)
        }
        // 沿上眼睑的一条由细到粗的线，贴着睫毛根、往上长。
        var bottom: [MKVec] = [], top: [MKVec] = []
        for s in 0...16 {
            let t = CGFloat(s) / 16
            let lid = e.upper.at(t)
            let thick = w * (thickStart + (thickEnd - thickStart) * mkSmoothstep(0, 1, t)) * (t < 0.06 ? t / 0.06 : 1)
            bottom.append(lid - e.up * (w * 0.004))
            top.append(lid + e.up * thick)
        }
        p.fill(bottom + top.reversed())
        if let wing {
            // 翘尾：从眼尾接着往外上方收成一个细尖；再把眼尾上方那个小凹口填一下，线条才顺。
            let tip = e.outer + e.axis * (w * wing.out) + e.up * (w * wing.rise)
            let top = e.outer + e.up * (w * thickEnd * 1.15)
            p.fill([e.outer - e.up * (w * 0.006), tip, top])
            p.fill([e.upper.at(0.9) + e.up * (w * thickEnd * 0.9), top.lerp(tip, 0.45), top])
        }
        if style == .full {
            var line: [MKVec] = []
            for s in 0...10 { line.append(e.lower.at(0.35 + 0.65 * CGFloat(s) / 10) - e.up * (w * 0.004)) }
            p.tapered(line, half: { w * 0.011 * mkSmoothstep(0, 0.6, $0) })
        }
    }

    private func drawLashes(_ p: MKPainter, _ e: MKEye, _ style: MKLashStyle, index: Int) {
        let w = e.width
        var random = MKRandom(seed: 0x1A5 + UInt64(index) &* 7 &+ UInt64(style.rawValue))
        var count = 22
        var scale: CGFloat = 1
        var thickness: CGFloat = 0.0085
        switch style {
        case .natural: count = 24; scale = 0.85
        case .dense: count = 40; scale = 1.05; thickness = 0.0095
        case .sunflower: count = 15; scale = 1.25; thickness = 0.012
        case .doll: count = 30; scale = 1.18; thickness = 0.010
        }
        for k in 0..<count {
            var f = CGFloat(k) / CGFloat(count - 1)
            if style != .sunflower { f = min(max(f + random.range(-0.5, 0.5) / CGFloat(count), 0), 1) }
            let t = 0.10 + 0.90 * f
            let base = e.upper.at(t) + e.up * (w * 0.004)
            // 内眼角的睫毛朝里上方，越往外越朝外上方，像一把打开的扇子。
            let fan = -0.30 + 1.05 * f + (style == .sunflower ? 0 : random.range(-0.07, 0.07))
            let direction = (e.up + e.axis * fan).unit
            var length = w * (0.09 + 0.10 * sin(.pi * pow(f, 0.8))) * scale
            if f > 0.7 { length *= 1 + 0.25 * (f - 0.7) / 0.3 }
            if style == .sunflower { length *= k % 2 == 0 ? 1.0 : 0.72 } else { length *= random.range(0.78, 1.08) }
            let tip = base + direction * length
            // 先顺着眼睑往外长，再往上翘。
            let control = base + (e.up * 0.35 + e.axis * (fan * 1.9)).unit * (length * 0.5)
            p.tapered(MKPainter.bezier(base, control, tip), half: { w * thickness * (1 - 0.92 * $0) },
                      alpha: style == .natural ? 0.85 : 1)
        }
        guard style == .doll || style == .dense else { return }
        // 下睫毛：短、稀，朝外下方。
        let lower = style == .doll ? 13 : 9
        for k in 0..<lower {
            let f = CGFloat(k) / CGFloat(lower - 1)
            let t = 0.30 + 0.66 * f
            let base = e.lower.at(t)
            let direction = (-e.up + e.axis * (0.15 + 0.6 * f)).unit
            let length = w * (style == .doll ? 0.075 : 0.05) * (0.7 + 0.5 * f) * random.range(0.8, 1.1)
            p.tapered([base, base + direction * (length * 0.5), base + direction * length],
                      half: { w * 0.0065 * (1 - 0.9 * $0) }, alpha: 0.9)
        }
    }

    private func drawFold(_ p: MKPainter, _ e: MKEye, _ style: MKFoldStyle) {
        let w = e.width
        var line: [MKVec] = []
        for s in 0...16 {
            let t = CGFloat(s) / 16
            let offset: CGFloat
            switch style {
            case .fan: offset = 0.105 * mkSmoothstep(0, 0.5, t) * (1 - 0.2 * mkSmoothstep(0.8, 1, t))
            case .parallel: offset = 0.06 + 0.035 * sin(.pi * (0.1 + 0.75 * t))
            }
            line.append(e.upper.at(0.03 + 0.97 * t) + e.up * (w * offset) + e.axis * (w * 0.05 * t * t))
        }
        p.tapered(line, half: { w * 0.011 * pow(sin(.pi * min(max($0, 0.02), 0.98)), 0.5) })
    }

    private func drawCatchlight(_ p: MKPainter, _ e: MKEye, _ style: MKCatchlight) {
        let r = irisRadius(e)
        let main = e.center - right * (r * 0.32) + up * (r * 0.36)
        p.clipped(to: e.outline) {
            switch style {
            case .dot:
                p.blob(main, rx: r * 0.26, ry: r * 0.26)
            case .twin:
                p.blob(main, rx: r * 0.26, ry: r * 0.26)
                p.blob(e.center + right * (r * 0.34) - up * (r * 0.30), rx: r * 0.13, ry: r * 0.13, alpha: 0.85)
            case .window:
                let a = right * (r * 0.19), b = up * (r * 0.15)
                p.fill([main - a - b, main + a - b, main + a + b, main - a + b], alpha: 0.95)
                p.stroke([main - b, main + b], width: r * 0.035, gray: 0)
                p.stroke([main - a, main + a], width: r * 0.035, gray: 0)
            case .star:
                var star: [MKVec] = []
                for k in 0..<8 {
                    let angle = CGFloat(k) / 8 * 2 * .pi
                    let radius = r * (k % 2 == 0 ? 0.36 : 0.09)
                    star.append(main + right * (cos(angle) * radius) + up * (sin(angle) * radius))
                }
                p.fill(star)
                p.blob(e.center + right * (r * 0.34) - up * (r * 0.30), rx: r * 0.1, ry: r * 0.1, alpha: 0.8)
            case .ring:
                var arc: [MKVec] = []
                for k in 0...40 {
                    let angle = (-0.35 + 1.7 * CGFloat(k) / 40) * .pi
                    arc.append(e.center + right * (cos(angle) * r * 0.5) - up * (sin(angle) * r * 0.5))
                }
                p.stroke(arc, width: r * 0.075, alpha: 0.9)
            }
        }
    }

    // MARK: 修容

    private func drawNose(_ p: MKPainter, light: Bool) {
        if light {
            var line: [MKVec] = []
            for s in 0...12 { line.append(ridge.at(0.14 + 0.66 * CGFloat(s) / 12)) }
            p.stroke(line, width: eyeDist * 0.045)
            p.blob(ridge.at(0.95), rx: eyeDist * 0.065, ry: eyeDist * 0.055, axis: right)
            return
        }
        let average = max((eyes[0].side + eyes[1].side) / 2, 1e-4)
        for (i, e) in eyes.enumerated() {
            // 侧脸时远离镜头那一侧的鼻影要收窄，不然会画到脸颊上。
            let ratio = 0.45 + 0.55 * min(e.side / average, 1.3)
            let sideways = (i == 0 ? -right : right)
            var line: [MKVec] = []
            for s in 0...12 {
                let t = 0.04 + 0.74 * CGFloat(s) / 12
                line.append(ridge.at(t) + sideways * (eyeDist * (0.085 + 0.055 * t) * ratio))
            }
            p.stroke(line, width: eyeDist * 0.06)
            // 眉头下面那一小段，把鼻影和眉毛接起来。
            if let brow = brows[i] {
                p.stroke([brow.center.at(0.04) - brow.up * (brow.length * 0.1), line[0]], width: eyeDist * 0.05, alpha: 0.7)
            }
        }
    }

    private func drawFreckles(_ p: MKPainter, _ style: MKFreckleStyle) {
        var random = MKRandom(seed: 0xF2EC + UInt64(style.rawValue))
        let count: Int
        switch style {
        case .few: count = 36
        case .natural: count = 84
        case .sun: count = 150
        }
        let visibleSides = eyes.enumerated().filter { $0.element.visible }
        for _ in 0..<count {
            let pick = random.next()
            var point: MKVec
            if pick < 0.42 || visibleSides.isEmpty {
                point = ridge.at(0.6) + right * (random.gauss() * eyeDist * 0.2) + down * (random.gauss() * mouthDist * 0.1)
            } else {
                let (i, e) = visibleSides[Int(random.next() * CGFloat(visibleSides.count)) % visibleSides.count]
                let outward = i == 0 ? -right : right
                let center = e.center + down * (mouthDist * 0.42) + outward * (e.side * 0.12)
                point = center + right * (random.gauss() * e.side * 0.36) + down * (random.gauss() * mouthDist * 0.15)
            }
            // 不画到眼睛里和嘴上。
            if eyes.contains(where: { point.dist($0.center) < $0.width * 0.62 }) { continue }
            if (point - mouthCenter).dot(down) > -mouthDist * 0.12 { continue }
            p.dot(point, radius: eyeDist * random.range(0.004, 0.010), alpha: random.range(0.35, 1))
        }
    }

    /// 一颗痣在这张脸方框里的位置。
    func position(of spot: MKMoleSpot, imageSize: CGSize) -> MKVec? {
        switch spot {
        case .tearLeft:
            return eyes[0].lower.at(0.72) + down * (eyes[0].width * 0.20)
        case .tearRight:
            return eyes[1].lower.at(0.72) + down * (eyes[1].width * 0.20)
        case .lip:
            let i = eyes[1].visible ? 1 : 0
            let outward = i == 0 ? -right : right
            return lipTop + outward * (mouthWidth * 0.36) + up * (mouthDist * 0.09)
        case .nose:
            return ridge.at(0.5) + (eyes[0].side >= eyes[1].side ? -right : right) * (eyeDist * 0.06)
        case .cheek:
            let i = eyes[0].side >= eyes[1].side ? 0 : 1
            let outward = i == 0 ? -right : right
            return eyes[i].center + down * (mouthDist * 0.62) + outward * (eyes[i].side * 0.30)
        case .chin:
            let i = eyes[0].side >= eyes[1].side ? 0 : 1
            return lipBottom + (i == 0 ? -right : right) * (mouthWidth * 0.30) + down * (mouthDist * 0.14)
        case .custom(let x, let y):
            guard imageSize.width > 0, roi.width > 0 else { return nil }
            return MKVec((CGFloat(x) / 10000 * imageSize.width - roi.minX) / roi.width,
                         (CGFloat(y) / 10000 * imageSize.height - roi.minY) / roi.height)
        }
    }

    private func drawMoles(_ p: MKPainter, _ spots: [MKMoleSpot], imageSize: CGSize) {
        for spot in spots {
            guard let point = position(of: spot, imageSize: imageSize) else { continue }
            let r = eyeDist * 0.013
            p.dot(point, radius: r)
            p.blob(point, rx: r * 1.7, ry: r * 1.7, alpha: 0.5)
        }
    }
}

// MARK: - 蒙版缓存

/// 画好的蒙版按"哪张脸 + 什么形状 + 多大"记住。拖动浓淡、换颜色时只是重新调色，不用再画。
/// 总量按占的内存限制，超了就把最早画的丢掉。
final class MKMaskCache {
    static let shared = MKMaskCache()

    struct Key: Hashable {
        let face: Int
        let shape: MKShape
        let size: Int
    }

    private var store: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private let lock = NSLock()
    private let limit = 48 * 1024 * 1024

    func image(_ key: Key, make: () -> CGImage?) -> CGImage? {
        lock.lock()
        if let hit = store[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let made = make() else { return nil }
        lock.lock()
        if store[key] == nil {
            store[key] = made
            order.append(key)
            bytes += key.size * key.size
            while bytes > limit, order.count > 1 {
                let old = order.removeFirst()
                if store.removeValue(forKey: old) != nil { bytes -= old.size * old.size }
            }
        }
        lock.unlock()
        return made
    }

    func removeAll() {
        lock.lock()
        store.removeAll()
        order.removeAll()
        bytes = 0
        lock.unlock()
    }
}
