import CoreGraphics
import CoreImage

/// 特效里用 CoreGraphics 画的东西：粒子、光束、光斑、图案。尺寸都按画面长边的比例。
enum EffectDraw {
    /// 在长边不超过 2048 的透明画布上画，再放大到 size。
    static func overlay(size: CGSize, seed: UInt64, chaos: CGFloat = 0.5,
                        draw: (CGContext, CGSize, inout EffectRNG) -> Void) -> CIImage? {
        let long = max(size.width, size.height)
        guard long >= 2 else { return nil }
        let k = min(1, 2048 / long)
        let w = max(2, Int((size.width * k).rounded())), h = max(2, Int((size.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rng = EffectRNG(seed: seed, chaos: chaos)
        draw(ctx, CGSize(width: w, height: h), &rng)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(w), y: size.height / CGFloat(h)))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        rgb(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a)
    }

    /// 中间亮、边上透明的一团光。
    private static func glow(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor, core: CGFloat = 0) {
        let clear = color.copy(alpha: 0) ?? color
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color, color, clear] as CFArray,
                                 locations: [0, core, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }

    /// 四角星（闪光）。
    private static func sparkle(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor, rotation: CGFloat = 0) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: rotation)
        let path = CGMutablePath()
        let n = 4
        for i in 0..<(n * 2) {
            let a = CGFloat(i) * .pi / CGFloat(n) + .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.14
            let p = CGPoint(x: cos(a) * rr, y: sin(a) * rr)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
        glow(ctx, c, r * 0.55, color.copy(alpha: (color.alpha) * 0.45) ?? color)
    }

    private static func heart(_ ctx: CGContext, _ c: CGPoint, _ s: CGFloat, _ color: CGColor, rotation: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: rotation)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -s * 0.5))
        p.addCurve(to: CGPoint(x: -s * 0.5, y: s * 0.12), control1: CGPoint(x: -s * 0.2, y: -s * 0.25),
                   control2: CGPoint(x: -s * 0.5, y: -s * 0.15))
        p.addArc(center: CGPoint(x: -s * 0.25, y: s * 0.14), radius: s * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addArc(center: CGPoint(x: s * 0.25, y: s * 0.14), radius: s * 0.25, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addCurve(to: CGPoint(x: 0, y: -s * 0.5), control1: CGPoint(x: s * 0.5, y: -s * 0.15),
                   control2: CGPoint(x: s * 0.2, y: -s * 0.25))
        ctx.addPath(p)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// 两头尖的叶片 / 花瓣。
    private static func leaf(_ ctx: CGContext, _ c: CGPoint, length: CGFloat, width: CGFloat, rotation: CGFloat,
                             _ color: CGColor, notch: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: rotation)
        let p = CGMutablePath()
        let l = length / 2
        p.move(to: CGPoint(x: -l, y: 0))
        p.addQuadCurve(to: CGPoint(x: l, y: 0), control: CGPoint(x: 0, y: width))
        if notch {
            // 樱花瓣尖上有个小缺口。
            p.addLine(to: CGPoint(x: l * 0.82, y: -width * 0.08))
            p.addLine(to: CGPoint(x: l * 0.95, y: -width * 0.3))
        }
        p.addQuadCurve(to: CGPoint(x: -l, y: 0), control: CGPoint(x: 0, y: -width))
        ctx.addPath(p)
        ctx.setFillColor(color)
        ctx.fillPath()
        if !notch {
            ctx.setStrokeColor(rgb(0, 0, 0, 0.18))
            ctx.setLineWidth(max(0.5, width * 0.06))
            ctx.move(to: CGPoint(x: -l, y: 0))
            ctx.addLine(to: CGPoint(x: l * 0.9, y: 0))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: 氛围粒子

    static func particles(_ kind: EffectKind, ctx: CGContext, size: CGSize, rng: inout EffectRNG) {
        let W = size.width, H = size.height
        let u = max(W, H)
        func pt() -> CGPoint { CGPoint(x: CGFloat(rng.next()) * W, y: CGFloat(rng.next()) * H) }
        func r(_ a: Double, _ b: Double) -> CGFloat { CGFloat(rng.range(a, b)) }
        let density = W * H / (u * u) // 横竖图粒子密度一样
        func count(_ n: Double) -> Int { max(1, Int(n * Double(density) * 1.4)) }
        switch kind {
        case .goldGlitter:
            let golds: [UInt32] = [0xFFD66B, 0xFFF0B8, 0xF2B544, 0xFFE28A, 0xE8A33A]
            for _ in 0..<count(320) {
                let c = pt()
                let rad = u * r(0.0012, 0.0042)
                ctx.setFillColor(hex(golds[Int(rng.next() * Double(golds.count)) % golds.count], r(0.55, 1)))
                ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
            }
            for _ in 0..<count(22) {
                sparkle(ctx, pt(), u * r(0.008, 0.022), hex(0xFFF3C4, r(0.7, 1)), rotation: r(-0.3, 0.3))
            }
        case .twinkle:
            for _ in 0..<count(110) {
                let c = pt()
                let rad = u * r(0.001, 0.0028)
                ctx.setFillColor(rgb(1, 1, 1, r(0.4, 0.9)))
                ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
            }
            for _ in 0..<count(34) {
                sparkle(ctx, pt(), u * r(0.008, 0.032), rgb(1, 1, 0.97, r(0.65, 1)), rotation: r(-0.15, 0.15))
            }
        case .snow, .colorSnow:
            let colors: [UInt32] = [0xFFB3C7, 0xB3E0FF, 0xFFF1A8, 0xC9B8FF, 0xB8FFD6, 0xFFFFFF]
            for _ in 0..<count(kind == .snow ? 260 : 220) {
                let c = pt()
                // 有大有小：大的离镜头近，更虚。
                let near = rng.next() < 0.12
                let rad = u * (near ? r(0.008, 0.016) : r(0.0015, 0.005))
                let color = kind == .snow ? rgb(1, 1, 1, near ? r(0.35, 0.6) : r(0.6, 0.95))
                    : hex(colors[Int(rng.next() * Double(colors.count)) % colors.count], near ? 0.5 : r(0.7, 1))
                glow(ctx, c, rad, color, core: near ? 0.1 : 0.55)
            }
        case .petals:
            let pinks: [UInt32] = [0xFFC7D9, 0xFFB0C8, 0xFFDCE6, 0xF9A6BF]
            for _ in 0..<count(70) {
                let len = u * r(0.012, 0.026)
                leaf(ctx, pt(), length: len, width: len * r(0.38, 0.5), rotation: r(0, 6.28),
                     hex(pinks[Int(rng.next() * Double(pinks.count)) % pinks.count], r(0.75, 0.95)), notch: true)
            }
        case .leaves:
            let autumn: [UInt32] = [0xD9541E, 0xE8862A, 0xF2B33D, 0xB8341B, 0xC96A1F, 0x9A4A1A]
            for _ in 0..<count(48) {
                let len = u * r(0.016, 0.038)
                leaf(ctx, pt(), length: len, width: len * r(0.3, 0.42), rotation: r(0, 6.28),
                     hex(autumn[Int(rng.next() * Double(autumn.count)) % autumn.count], r(0.85, 1)), notch: false)
            }
        case .confetti:
            let bright: [UInt32] = [0xFF4D6D, 0xFFC93C, 0x3CC8FF, 0x7CFF6B, 0xB46BFF, 0xFF8A3C, 0xFFFFFF, 0xFF6BD5]
            func pick() -> CGColor { hex(bright[Int(rng.next() * Double(bright.count)) % bright.count], r(0.85, 1)) }
            for _ in 0..<count(170) {
                let c = pt()
                let w = u * r(0.004, 0.009), h = w * r(1.4, 2.4)
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: r(0, 6.28))
                ctx.setFillColor(pick())
                ctx.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                ctx.restoreGState()
            }
            // 卷曲的彩带。
            for _ in 0..<count(14) {
                let start = pt()
                let len = u * r(0.05, 0.1)
                let ang = r(0, 6.28)
                let end = CGPoint(x: start.x + cos(ang) * len, y: start.y + sin(ang) * len)
                let bend = u * r(0.02, 0.04)
                ctx.setStrokeColor(pick())
                ctx.setLineWidth(u * r(0.0025, 0.004))
                ctx.setLineCap(.round)
                ctx.move(to: start)
                ctx.addCurve(to: end,
                             control1: CGPoint(x: start.x + cos(ang + 1.3) * bend + cos(ang) * len * 0.33,
                                               y: start.y + sin(ang + 1.3) * bend + sin(ang) * len * 0.33),
                             control2: CGPoint(x: start.x + cos(ang - 1.3) * bend + cos(ang) * len * 0.66,
                                               y: start.y + sin(ang - 1.3) * bend + sin(ang) * len * 0.66))
                ctx.strokePath()
            }
        case .hearts:
            let reds: [UInt32] = [0xFF4D7A, 0xFF8FAB, 0xFF2E55, 0xFFB3C6, 0xE0245E]
            for _ in 0..<count(40) {
                heart(ctx, pt(), u * r(0.012, 0.04),
                      hex(reds[Int(rng.next() * Double(reds.count)) % reds.count], r(0.55, 0.92)), rotation: r(-0.4, 0.4))
            }
        case .bubbles:
            for _ in 0..<count(34) {
                let c = pt()
                let rad = u * r(0.008, 0.035)
                glow(ctx, c, rad, rgb(0.85, 0.95, 1, 0.07), core: 0.7)
                ctx.setStrokeColor(rgb(1, 1, 1, r(0.45, 0.75)))
                ctx.setLineWidth(max(0.8, u * 0.0016))
                ctx.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                let hr = rad * 0.28
                ctx.setFillColor(rgb(1, 1, 1, 0.7))
                ctx.fillEllipse(in: CGRect(x: c.x - rad * 0.55 - hr / 2, y: c.y + rad * 0.35 - hr / 4, width: hr, height: hr * 0.6))
            }
        case .fireflies:
            for _ in 0..<count(70) {
                let c = pt()
                let rad = u * r(0.003, 0.009)
                glow(ctx, c, rad * 3, rgb(1, 0.92, 0.45, r(0.12, 0.25)))
                glow(ctx, c, rad, rgb(1, 1, 0.8, 0.95), core: 0.4)
            }
        case .rain:
            ctx.setLineCap(.round)
            let ang = -CGFloat.pi / 2 + 0.22
            for _ in 0..<count(520) {
                let c = pt()
                let len = u * r(0.025, 0.07)
                ctx.setStrokeColor(rgb(0.92, 0.95, 1, r(0.18, 0.45)))
                ctx.setLineWidth(max(0.6, u * r(0.0006, 0.0013)))
                ctx.move(to: c)
                ctx.addLine(to: CGPoint(x: c.x + cos(ang) * len, y: c.y + sin(ang) * len))
                ctx.strokePath()
            }
        default:
            break
        }
    }

    // MARK: 光

    /// 从上面一个角斜射下来的光束。
    static func godRays(_ ctx: CGContext, size: CGSize, rng: inout EffectRNG, fromLeft: Bool, color c: EffectVariant) {
        let W = size.width, H = size.height
        let u = max(W, H)
        let source = CGPoint(x: fromLeft ? -W * 0.08 : W * 1.08, y: H * 1.1)
        let toward = atan2(-H, fromLeft ? W * 0.7 : -W * 0.7)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        for _ in 0..<11 {
            let a = toward + CGFloat(rng.range(-0.42, 0.42))
            let half = CGFloat(rng.range(0.008, 0.035))
            let reach = u * CGFloat(rng.range(1.0, 1.5))
            let alpha = CGFloat(rng.range(0.25, 0.6))
            let path = CGMutablePath()
            path.move(to: source)
            path.addLine(to: CGPoint(x: source.x + cos(a - half) * reach, y: source.y + sin(a - half) * reach))
            path.addLine(to: CGPoint(x: source.x + cos(a + half) * reach, y: source.y + sin(a + half) * reach))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let col = rgb(c.r, c.g, c.b, alpha)
            if let g = CGGradient(colorsSpace: space, colors: [col, col.copy(alpha: 0) ?? col] as CFArray, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: source, startRadius: 0, endCenter: source, endRadius: reach, options: [])
            }
            ctx.restoreGState()
        }
        glow(ctx, source, u * 0.45, rgb(c.r, c.g, c.b, 0.55))
    }

    /// 一道斜着的彩虹色光带。
    static func rainbow(_ ctx: CGContext, size: CGSize, rng: inout EffectRNG) {
        let W = size.width, H = size.height
        let u = max(W, H)
        let colors = [0xFF3B3B, 0xFF9A2E, 0xFFE93B, 0x4BE36B, 0x3BB8FF, 0x6B5BFF, 0xC04BFF].map { hex(UInt32($0), 0.55) }
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) else { return }
        ctx.saveGState()
        ctx.translateBy(x: W * CGFloat(rng.range(0.25, 0.55)), y: H * 0.5)
        ctx.rotate(by: CGFloat(rng.range(0.5, 0.9)))
        let band = u * 0.09
        ctx.clip(to: CGRect(x: -band / 2, y: -u, width: band, height: u * 2))
        ctx.drawLinearGradient(g, start: CGPoint(x: -band / 2, y: 0), end: CGPoint(x: band / 2, y: 0), options: [])
        ctx.restoreGState()
    }

    /// 焦外的圆形光斑。color 为空时用彩色。
    static func bokehSpots(_ ctx: CGContext, size: CGSize, rng: inout EffectRNG, color: EffectVariant?) {
        let W = size.width, H = size.height
        let u = max(W, H)
        let palette: [UInt32] = [0xFF8FB1, 0xFFD36B, 0x7FD8FF, 0xB79BFF, 0x8CFFB5]
        let n = Int(30 * W * H / (u * u) * 1.4) + 8
        for _ in 0..<n {
            let c = CGPoint(x: CGFloat(rng.next()) * W, y: CGFloat(rng.next()) * H)
            let rad = u * CGFloat(rng.range(0.015, 0.06))
            let a = CGFloat(rng.range(0.16, 0.38))
            let col: CGColor
            if let color { col = rgb(color.r, color.g, color.b, a) } else {
                col = hex(palette[Int(rng.next() * Double(palette.count)) % palette.count], a)
            }
            ctx.setFillColor(col)
            ctx.fillEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
            // 边缘一圈略亮，像镜头的光斑。
            ctx.setStrokeColor(col.copy(alpha: min(1, a * 1.6)) ?? col)
            ctx.setLineWidth(max(1, rad * 0.06))
            ctx.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
        }
    }

    /// 树叶缝里漏下来的光（白 = 亮）。
    static func leafPattern(_ ctx: CGContext, size: CGSize, rng: inout EffectRNG) {
        let W = size.width, H = size.height
        let u = max(W, H)
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(rgb(1, 1, 1))
        // 一簇一簇的光斑，簇里大小不一。
        for _ in 0..<Int(55 * W * H / (u * u) * 1.4 + 16) {
            let center = CGPoint(x: CGFloat(rng.next()) * W, y: CGFloat(rng.next()) * H)
            for _ in 0..<9 {
                let c = CGPoint(x: center.x + u * CGFloat(rng.range(-0.045, 0.045)), y: center.y + u * CGFloat(rng.range(-0.045, 0.045)))
                let rw = u * CGFloat(rng.range(0.003, 0.014)), rh = rw * CGFloat(rng.range(0.45, 1))
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: CGFloat(rng.range(0, 3.14)))
                ctx.fillEllipse(in: CGRect(x: -rw, y: -rh, width: rw * 2, height: rh * 2))
                ctx.restoreGState()
            }
        }
    }

    /// 百叶窗的条纹光影（白 = 亮）。
    static func blindsPattern(_ ctx: CGContext, size: CGSize) {
        let W = size.width, H = size.height
        let u = max(W, H)
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.saveGState()
        ctx.translateBy(x: W / 2, y: H / 2)
        ctx.rotate(by: -0.42)
        ctx.setFillColor(rgb(1, 1, 1))
        let period = u * 0.065
        var y = -u
        while y < u {
            ctx.fill(CGRect(x: -u, y: y, width: u * 2, height: period * 0.52))
            y += period
        }
        ctx.restoreGState()
    }

    /// LED 屏的点阵（白点 + 黑缝）。
    static func ledDots(_ ctx: CGContext, size: CGSize, columns: Int) {
        let W = size.width, H = size.height
        let cell = max(W, H) / CGFloat(columns)
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(rgb(1, 1, 1))
        let rad = cell * 0.4
        var x = cell / 2
        while x < W + cell {
            var y = cell / 2
            while y < H + cell {
                ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
                y += cell
            }
            x += cell
        }
    }

    /// 星芒：在画面最亮的几处画出放射状的星芒。
    static func stars(_ image: CIImage, points: Int, seed: UInt64 = 1, chaos: CGFloat = 0.5) -> CIImage? {
        let e = image.extent
        // 缩成很小的图找亮点；位置是比例，所以预览和原图找到的一样。
        let small = Renderer.shared.downscaled(image, maxDimension: 72)
        guard let cg = Renderer.shared.context.createCGImage(small, from: small.extent, format: .RGBA8,
                                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let w = cg.width, h = cg.height
        guard w >= 3, h >= 3 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        // 画布只在这个闭包里用，指针一直有效。
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        func lum(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return (0.3 * Double(px[i]) + 0.59 * Double(px[i + 1]) + 0.11 * Double(px[i + 2])) / 255
        }
        // 局部最亮、而且够亮的点（行 0 是图的上边）。
        var found: [(x: Double, y: Double, v: Double)] = []
        var maxL = 0.0
        for y in 0..<h { for x in 0..<w { maxL = max(maxL, lum(x, y)) } }
        let threshold = max(0.78, maxL * 0.93)
        for y in 1..<max(1, h - 1) {
            for x in 1..<max(1, w - 1) {
                let v = lum(x, y)
                guard v >= threshold else { continue }
                var peak = true
                for dy in -1...1 { for dx in -1...1 where (dx != 0 || dy != 0) && lum(x + dx, y + dy) > v { peak = false } }
                if peak { found.append(((Double(x) + 0.5) / Double(w), 1 - (Double(y) + 0.5) / Double(h), v)) }
            }
        }
        found.sort { $0.v > $1.v }
        // 太近的只留一个。
        var picked: [(x: Double, y: Double, v: Double)] = []
        for f in found where picked.count < 12 {
            if picked.allSatisfy({ hypot($0.x - f.x, $0.y - f.y) > 0.08 }) { picked.append(f) }
        }
        guard !picked.isEmpty else { return nil }
        return overlay(size: e.size, seed: seed, chaos: chaos) { ctx, size, rng in
            let u = max(size.width, size.height)
            for (i, f) in picked.enumerated() {
                let c = CGPoint(x: CGFloat(f.x) * size.width, y: CGFloat(f.y) * size.height)
                let len = u * (i == 0 ? 0.17 : 0.1) * CGFloat(0.6 + (f.v - threshold) / max(0.01, 1 - threshold) * 0.4)
                ray(ctx, c, length: len * CGFloat(rng.range(0.8, 1.2)), points: points, rng: &rng)
            }
        }
    }

    private static func ray(_ ctx: CGContext, _ c: CGPoint, length: CGFloat, points: Int, rng: inout EffectRNG) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        // 整颗星转一个小角度，每根芒长短不一（随机度越高差得越多）。
        let turn = CGFloat(rng.range(-0.12, 0.12))
        for i in 0..<points {
            let a = CGFloat(i) * .pi / CGFloat(points) * 2 + .pi / 4 + turn
            let each = length * CGFloat(rng.range(0.85, 1.15))
            let end = CGPoint(x: c.x + cos(a) * each, y: c.y + sin(a) * each)
            let half = length * 0.028
            let n = CGPoint(x: -sin(a) * half, y: cos(a) * half)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: c.x + n.x, y: c.y + n.y))
            path.addLine(to: end)
            path.addLine(to: CGPoint(x: c.x - n.x, y: c.y - n.y))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let white = rgb(1, 0.97, 0.9, 1)
            if let g = CGGradient(colorsSpace: space, colors: [white, white.copy(alpha: 0) ?? white] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: c, end: end, options: [])
            }
            ctx.restoreGState()
        }
        glow(ctx, c, length * 0.16, rgb(1, 0.97, 0.9, 0.9), core: 0.15)
    }
}
