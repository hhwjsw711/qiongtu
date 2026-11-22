import CoreImage
import CoreGraphics

/// 特效的实现。输入的图原点在 (0,0)；mask 已经和图对齐（白 = 主体）。
enum EffectRender {
    static func render(_ kind: EffectKind, image: CIImage, strength s: CGFloat, variant v: EffectVariant,
                       variantIndex: Int, seed: UInt64, chaos: CGFloat, mask: CIImage?) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        switch kind {
        // MARK: 光
        case .blackMist:
            // 黑柔：高光往外晕开，反差略降，暗部仍然是黑的，只带一点点雾。
            let hi = highlights(image, from: 0.55)
            let glow = add(scale(blurLow(hi, dim * 0.022), 0.95), scale(blurLow(hi, dim * 0.006), 0.55))
            var out = screen(scale(glow, 0.75 * s), over: image)
            out = out.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0.025 * s),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + 0.01 * s),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 - 0.02 * s),
                "inputPoint4": CIVector(x: 1, y: 1 - 0.03 * s),
            ])
            return out.cropped(to: e)
        case .whiteMist:
            // 白柔：整张画面都起一层柔光，暗部被提起来，更梦幻。
            let glow = blurLow(image, dim * 0.018)
            var out = screen(scale(glow, 0.55 * s), over: image)
            out = out.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0.07 * s),
                "inputPoint1": CIVector(x: 0.25, y: 0.27 + 0.03 * s),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.02 * s),
                "inputPoint3": CIVector(x: 0.75, y: 0.75),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
            return out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - 0.1 * s]).cropped(to: e)
        case .softFocus:
            let soft = blurLow(image, dim * 0.012).applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            return FX.mix(image, soft.cropped(to: e), t: 0.85 * s)
        case .rimLight:
            guard let mask else { return image }
            return rimLight(image, mask: mask, strength: s, color: v)
        case .sunFlare:
            return sunFlare(image, strength: s, color: v)
        case .starburst:
            let points = variantIndex == 1 ? 6 : (variantIndex == 2 ? 8 : 4)
            guard let overlay = EffectDraw.stars(image, points: points, seed: seed, chaos: chaos) else { return image }
            return screen(scale(overlay, s), over: image)
        case .godRays:
            guard let rays = EffectDraw.overlay(size: e.size, seed: seed, chaos: chaos, draw: { ctx, size, rng in
                EffectDraw.godRays(ctx, size: size, rng: &rng, fromLeft: variantIndex == 0, color: v)
            }) else { return image }
            return screen(scale(blurLow(rays, dim * 0.012), 1.1 * s), over: image)
        case .lightLeak:
            return lightLeak(image, strength: s, color: v)
        case .rainbow:
            guard let band = EffectDraw.overlay(size: e.size, seed: seed, chaos: chaos, draw: { ctx, size, rng in
                EffectDraw.rainbow(ctx, size: size, rng: &rng)
            }) else { return image }
            return screen(scale(blurLow(band, dim * 0.022), 0.75 * s), over: image)
        case .bokehLight:
            guard let spots = EffectDraw.overlay(size: e.size, seed: seed, chaos: chaos, draw: { ctx, size, rng in
                EffectDraw.bokehSpots(ctx, size: size, rng: &rng, color: variantIndex == 2 ? nil : v)
            }) else { return image }
            return screen(scale(blurLow(spots, dim * 0.002), s), over: image)
        case .leafShadow, .blinds:
            guard let pattern = EffectDraw.overlay(size: e.size, seed: seed, chaos: chaos, draw: { ctx, size, rng in
                if kind == .leafShadow {
                    EffectDraw.leafPattern(ctx, size: size, rng: &rng)
                } else {
                    EffectDraw.blindsPattern(ctx, size: size)
                }
            }) else { return image }
            let soft = blurLow(pattern, dim * (kind == .leafShadow ? 0.0045 : 0.006))
            let lit = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.45])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5600, y: 0),
                ])
            let shade = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.7])
                .applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 7200, y: 0),
                ])
            let lighting = blend(lit.cropped(to: e), shade.cropped(to: e), mask: soft)
            return FX.mix(image, lighting, t: min(1, 1.05 * s))

        // MARK: 模糊
        case .bgBlur:
            guard let mask else { return image }
            let blurred = blurLow(image, dim * (0.004 + 0.03 * s))
            return blend(image, blurred, mask: feather(mask, dim * 0.002))
        case .bokeh:
            guard let mask else { return image }
            let back = lowres(image, 1200) { img in
                let d = max(img.extent.width, img.extent.height)
                return img.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [
                    kCIInputRadiusKey: d * (0.006 + 0.03 * s), "inputRingAmount": 0.0, "inputRingSize": 0.1,
                    "inputSoftness": 1.0,
                ]).cropped(to: img.extent)
            }
            let lifted = back.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.06])
            return blend(image, lifted, mask: feather(mask, dim * 0.002))
        case .defocus:
            return lowres(image, 1200) { img in
                let d = max(img.extent.width, img.extent.height)
                return img.clampedToExtent().applyingFilter("CIBokehBlur", parameters: [
                    kCIInputRadiusKey: d * (0.003 + 0.022 * s), "inputRingAmount": 0.0, "inputRingSize": 0.1,
                    "inputSoftness": 1.0,
                ]).cropped(to: img.extent)
            }
        case .motionBlur:
            let angle: CGFloat = variantIndex == 1 ? .pi / 2 : 0
            let moving = lowres(image, 1600) { img in
                let d = max(img.extent.width, img.extent.height)
                return img.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: d * (0.006 + 0.04 * s), kCIInputAngleKey: angle,
                ]).cropped(to: img.extent)
            }
            guard let mask else { return moving }
            return blend(image, moving, mask: feather(mask, dim * 0.002))
        case .zoomBlur:
            let zoomed = lowres(image, 1600) { img in
                let x = img.extent
                let d = max(x.width, x.height)
                return img.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: CIVector(x: x.midX, y: x.midY), "inputAmount": d * (0.01 + 0.06 * s),
                ]).cropped(to: x)
            }
            // 中心保持清楚。
            let center = radial(e, inner: dim * 0.08, outer: dim * 0.42)
            var out = blend(image, zoomed, mask: center)
            if let mask { out = blend(image, out, mask: feather(mask, dim * 0.002)) }
            return out
        case .ghost:
            return ghost(image, strength: s, mask: mask)
        case .longExposure:
            let streak = lowres(image, 1600) { img in
                let d = max(img.extent.width, img.extent.height)
                return img.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: d * 0.07, kCIInputAngleKey: 0.0,
                ]).cropped(to: img.extent)
            }
            let dreamy = streak.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: e)
            var out = FX.mix(image, dreamy, t: 0.75 * s)
            if let mask { out = blend(image, out, mask: scale(feather(mask, dim * 0.004), 0.75)) }
            return out
        case .gaussian:
            return blurLow(image, dim * (0.002 + 0.03 * s))

        // MARK: 复古
        case .vhs:
            var out = channelSplit(image, dx: dim * 0.004 * (0.4 + s))
            out = out.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: dim * 0.0012, kCIInputAngleKey: 0.0,
            ]).cropped(to: e)
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.82, kCIInputContrastKey: 0.92,
            ]).applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0.06), "inputPoint1": CIVector(x: 0.25, y: 0.28),
                "inputPoint2": CIVector(x: 0.5, y: 0.52), "inputPoint3": CIVector(x: 0.75, y: 0.76),
                "inputPoint4": CIVector(x: 1, y: 0.96),
            ])
            out = scanlines(out, period: e.height / 260, darkness: 0.22)
            return FX.mix(image, out.cropped(to: e), t: s)
        case .lowPixel:
            return image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputScaleKey: max(2, dim * (0.004 + 0.02 * s)),
            ]).cropped(to: e)
        case .led:
            let cell = dim / 90
            let pix = image.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: cell / 2, y: cell / 2), kCIInputScaleKey: cell,
            ]).cropped(to: e)
            guard let dots = EffectDraw.overlay(size: e.size, seed: 0, draw: { ctx, size, _ in
                EffectDraw.ledDots(ctx, size: size, columns: 90)
            }) else { return image }
            var out = multiply(pix.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25]), dots)
            out = FX.bloom(out.cropped(to: e), amount: 0.6)
            return FX.mix(image, out, t: s)
        case .neon:
            return neon(image, strength: s, color: v)
        case .glitch:
            return glitch(image, strength: s, seed: seed, chaos: chaos)
        case .crt:
            var out = image.clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: dim * 0.75, kCIInputScaleKey: 0.22,
            ]).cropped(to: e)
            out = channelSplit(out, dx: dim * 0.0018)
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.06, kCIInputContrastKey: 1.03,
            ])
            out = scanlines(out, period: e.height / 220, darkness: 0.3)
            out = FX.vignette(FX.bloom(out.cropped(to: e), amount: 0.35), amount: 1)
            return FX.mix(image, out.cropped(to: e), t: s)
        case .vaporwave:
            let mapped = image.applyingFilter("CIFalseColor", parameters: [
                "inputColor0": CIColor(red: 0.16, green: 0.03, blue: 0.36),
                "inputColor1": CIColor(red: 1, green: 0.62, blue: 0.86),
            ])
            var out = FX.mix(image, mapped, t: 0.55)
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.05])
            out = out.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: -0.18])
            return FX.mix(image, out.cropped(to: e), t: s)
        case .halftone:
            let dots = image.clampedToExtent().applyingFilter("CICMYKHalftone", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputWidthKey: max(3, dim / 130), kCIInputSharpnessKey: 0.7,
                kCIInputAngleKey: 0.0,
            ]).cropped(to: e)
            return FX.mix(image, dots, t: s)
        case .lofi:
            var out = blurLow(image, dim * 0.0012)
            out = out.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 9.0])
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.78, kCIInputContrastKey: 0.9,
            ]).applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0.08), "inputPoint1": CIVector(x: 0.25, y: 0.3),
                "inputPoint2": CIVector(x: 0.5, y: 0.52), "inputPoint3": CIVector(x: 0.75, y: 0.74),
                "inputPoint4": CIVector(x: 1, y: 0.92),
            ])
            return FX.mix(image, out.cropped(to: e), t: s)

        // MARK: 氛围
        default:
            guard let overlay = EffectDraw.overlay(size: e.size, seed: seed, chaos: chaos, draw: { ctx, size, rng in
                EffectDraw.particles(kind, ctx: ctx, size: size, rng: &rng)
            }) else { return image }
            return scale(overlay, min(1, 0.25 + 0.9 * s)).composited(over: image).cropped(to: e)
        }
    }

    // MARK: 轮廓光

    private static func rimLight(_ image: CIImage, mask: CIImage, strength s: CGFloat, color: EffectVariant) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        // 光的形状只跟蒙版有关，又很柔，在小图上算完放大，大图也快。
        let light = lowres(mask, 1400) { m in
            let x = m.extent
            let d = max(x.width, x.height)
            let eroded = m.clampedToExtent()
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: max(1, d * 0.006)])
                .cropped(to: x)
            // 边缘内侧的一圈亮带。
            let band = m.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: eroded]).cropped(to: x)
            let inner = multiply(blurPlain(band, d * 0.003), m)
            // 边缘外侧的一点光晕。
            let outside = m.applyingFilter("CIColorInvert")
            let halo = multiply(blurPlain(m, d * 0.02), outside)
            let sum = add(scale(inner, 1.5), scale(halo, 0.85)).cropped(to: x)
            // 从背后上方打过来：上面亮，下面弱。
            let grad = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: x.height), "inputPoint1": CIVector(x: 0, y: 0),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0.45, green: 0.45, blue: 0.45),
            ])?.outputImage?.cropped(to: x) ?? sum
            return multiply(sum, grad).cropped(to: x)
        }
        let tinted = light.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: color.r * 1.25 * s, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: color.g * 1.25 * s, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: color.b * 1.25 * s, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp")
        // 背景压暗一点，边缘光更跳。
        let darker = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.55 * s]).cropped(to: e)
        let base = blend(image, darker, mask: feather(mask, dim * 0.003))
        return screen(tinted, over: base).cropped(to: e)
    }

    // MARK: 光晕 / 漏光

    private static func sunFlare(_ image: CIImage, strength s: CGFloat, color c: EffectVariant) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        let sun = CGPoint(x: e.width * 0.84, y: e.height * 0.86)
        var out = image
        func disc(_ p: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ rgb: (CGFloat, CGFloat, CGFloat), _ a: CGFloat) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: p.x, y: p.y), "inputRadius0": r0, "inputRadius1": r1,
                "inputColor0": CIColor(red: rgb.0 * a, green: rgb.1 * a, blue: rgb.2 * a, alpha: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])?.outputImage?.cropped(to: e) ?? CIImage.empty()
        }
        // 大片暖光 + 太阳本身。
        out = screen(disc(sun, 0, dim * 0.75, (c.r, c.g, c.b), 0.75 * s), over: out)
        out = screen(disc(sun, dim * 0.015, dim * 0.13, (1, 0.98, 0.92), 0.95 * s), over: out)
        // 镜头里的鬼影：沿着太阳到画面中心的连线。
        let mid = CGPoint(x: e.midX, y: e.midY)
        let ghosts: [(CGFloat, CGFloat, (CGFloat, CGFloat, CGFloat), CGFloat)] = [
            (0.55, 0.025, (0.6, 1, 0.6), 0.22), (0.95, 0.06, (0.75, 0.6, 1), 0.16),
            (1.3, 0.018, (1, 0.7, 0.4), 0.28), (1.65, 0.1, (0.5, 0.8, 1), 0.12),
        ]
        for (t, r, rgb, a) in ghosts {
            let p = CGPoint(x: sun.x + (mid.x - sun.x) * t, y: sun.y + (mid.y - sun.y) * t)
            out = screen(disc(p, dim * r * 0.6, dim * r, rgb, a * s), over: out)
        }
        return out.cropped(to: e)
    }

    private static func lightLeak(_ image: CIImage, strength s: CGFloat, color c: EffectVariant) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        guard let side = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: e.midY), "inputPoint1": CIVector(x: e.width * 0.48, y: e.midY),
            "inputColor0": CIColor(red: c.r * 0.95, green: c.g * 0.95, blue: c.b * 0.95),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])?.outputImage?.cropped(to: e),
              let corner = CIFilter(name: "CIRadialGradient", parameters: [
                  "inputCenter": CIVector(x: e.width * 0.95, y: e.height * 0.97), "inputRadius0": 0.0,
                  "inputRadius1": dim * 0.55,
                  "inputColor0": CIColor(red: min(1, c.r * 0.6 + 0.4), green: min(1, c.g * 0.5 + 0.35), blue: c.b * 0.5 + 0.1),
                  "inputColor1": CIColor(red: 0, green: 0, blue: 0),
              ])?.outputImage?.cropped(to: e) else { return image }
        let leak = add(side, scale(corner, 0.8)).cropped(to: e)
        return screen(scale(leak, s), over: image).cropped(to: e)
    }

    // MARK: 模糊 / 复古

    private static func ghost(_ image: CIImage, strength s: CGFloat, mask: CIImage?) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        let step = dim * (0.012 + 0.03 * s)
        if let mask {
            // 只拖主体：主体的几个残影往后排，越远越淡。
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: e)
            let subject = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: feather(mask, dim * 0.002),
            ]).cropped(to: e)
            var out = image
            for k in stride(from: 4, through: 1, by: -1) {
                let a = (0.55 - 0.11 * CGFloat(k)) * s
                let copy = scaleAll(subject.transformed(by: CGAffineTransform(translationX: -step * CGFloat(k), y: 0)), a)
                out = copy.composited(over: out)
            }
            return subject.composited(over: out).cropped(to: e)
        }
        var out = image
        for k in 1...4 {
            let shifted = image.clampedToExtent().transformed(by: CGAffineTransform(translationX: -step * CGFloat(k), y: 0)).cropped(to: e)
            out = FX.mix(out, shifted, t: (0.32 - 0.06 * CGFloat(k)) * s)
        }
        return FX.mix(out, image, t: 0.35).cropped(to: e)
    }

    private static func neon(_ image: CIImage, strength s: CGFloat, color c: EffectVariant) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        // 边缘 = 原图和稍微模糊的图之差，再拉强。
        let raw = lowres(image, 1400) { img in
            let d = max(img.extent.width, img.extent.height)
            let soft = blurPlain(img, d * 0.001)
            return soft.applyingFilter("CIDifferenceBlendMode", parameters: [
                kCIInputBackgroundImageKey: blurPlain(img, d * 0.004),
            ]).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).cropped(to: img.extent)
        }
        let edges = scale(highlights(raw, from: 0.03), 1.6).applyingFilter("CIColorClamp")
        let line = edges.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: c.r * 1.4, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: c.g * 1.4, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: c.b * 1.4, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).applyingFilter("CIColorClamp")
        let glow = add(line, scale(blurLow(line, dim * 0.008), 2.2)).cropped(to: e)
        let dark = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.6])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.6])
        let out = screen(glow, over: dark.cropped(to: e))
        return FX.mix(image, out.cropped(to: e), t: s)
    }

    private static func glitch(_ image: CIImage, strength s: CGFloat, seed: UInt64, chaos: CGFloat) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        var out = channelSplit(image, dx: dim * 0.008 * (0.3 + s))
        var rng = EffectRNG(seed: seed &+ 99, chaos: chaos)
        let clamped = out.clampedToExtent()
        for _ in 0..<9 {
            let h = e.height * CGFloat(rng.range(0.008, 0.06))
            let y = e.height * CGFloat(rng.next())
            let dx = dim * CGFloat(rng.range(-0.06, 0.06)) * s
            let band = CGRect(x: 0, y: y, width: e.width, height: h)
            let piece = clamped.transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: band)
            out = piece.composited(over: out)
        }
        return FX.mix(image, out.cropped(to: e), t: min(1, 0.4 + s))
    }

    // MARK: 小工具

    /// 把 R、B 两个通道左右错开一点。
    static func channelSplit(_ image: CIImage, dx: CGFloat) -> CIImage {
        let e = image.extent
        let c = image.clampedToExtent()
        // 三层都不透明，各自只留一个通道，取每个通道的最大值拼回来（alpha 保持 1）。
        func only(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> CIImage {
            c.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        let red = only(1, 0, 0).transformed(by: CGAffineTransform(translationX: dx, y: 0))
        let green = only(0, 1, 0)
        let blue = only(0, 0, 1).transformed(by: CGAffineTransform(translationX: -dx, y: 0))
        func lighten(_ a: CIImage, _ b: CIImage) -> CIImage {
            a.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: b])
        }
        return lighten(lighten(red, green), blue).cropped(to: e)
    }

    /// 横向扫描线。period 是一条线的周期（像素）。
    static func scanlines(_ image: CIImage, period: CGFloat, darkness: CGFloat) -> CIImage {
        let e = image.extent
        guard period >= 1.5, let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            kCIInputCenterKey: CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: darkness),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            kCIInputWidthKey: period / 2, kCIInputSharpnessKey: 0.4,
        ])?.outputImage else { return image }
        let rotated = stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: e)
        return rotated.composited(over: image).cropped(to: e)
    }

    /// 只留比 t 亮的部分（拉伸到 0…1）。
    static func highlights(_ image: CIImage, from t: CGFloat) -> CIImage {
        let k = 1 / (1 - t)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -t * k, y: -t * k, z: -t * k, w: 0),
        ]).applyingFilter("CIColorClamp").cropped(to: image.extent)
    }

    /// 颜色乘以 k（不动 alpha）。
    static func scale(_ image: CIImage, _ k: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// 连 alpha 一起乘（预乘过的透明图层调不透明度）。
    static func scaleAll(_ image: CIImage, _ k: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
        ])
    }

    static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    static func screen(_ top: CIImage, over bottom: CIImage) -> CIImage {
        top.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: bottom]).cropped(to: bottom.extent)
    }

    /// mask 白的地方用 keep，黑的地方用 other。
    static func blend(_ keep: CIImage, _ other: CIImage, mask: CIImage) -> CIImage {
        keep.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: other, kCIInputMaskImageKey: mask,
        ]).cropped(to: keep.extent)
    }

    static func feather(_ mask: CIImage, _ r: CGFloat) -> CIImage { blurPlain(mask, r) }

    static func blurPlain(_ image: CIImage, _ r: CGFloat) -> CIImage {
        guard r > 0.3 else { return image }
        return image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: image.extent)
    }

    /// 大半径模糊：先缩小再模糊再放大，结果差不多，快得多。
    static func blurLow(_ image: CIImage, _ r: CGFloat) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        guard r > 6, dim > 900 else { return blurPlain(image, r) }
        let k = max(900 / dim, min(1, 8 / r))
        return lowres(image, dim * k) { blurPlain($0, r * k) }
    }

    /// 在长边不超过 maxDim 的小图上做 f，再放大回原尺寸。
    static func lowres(_ image: CIImage, _ maxDim: CGFloat, _ f: (CIImage) -> CIImage) -> CIImage {
        let e = image.extent
        let dim = max(e.width, e.height)
        guard dim > maxDim * 1.05 else { return f(image).cropped(to: e) }
        let k = maxDim / dim
        let small = image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .cropped(to: CGRect(x: 0, y: 0, width: e.width * k, height: e.height * k))
        let done = f(small)
        return done.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
            .cropped(to: e)
    }

    /// 中心白、外圈黑的圆形渐变（中间保留清楚用）。
    static func radial(_ e: CGRect, inner: CGFloat, outer: CGFloat) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: e.midX, y: e.midY), "inputRadius0": inner, "inputRadius1": outer,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1), "inputColor1": CIColor(red: 0, green: 0, blue: 0),
        ])?.outputImage?.cropped(to: e) ?? CIImage(color: .white).cropped(to: e)
    }
}

/// 固定种子的随机数（预览和保存画出来一样）。
struct EffectRNG {
    private var state: UInt64

    /// 随机范围放大 / 缩小的倍数：随机度 0.5 = 1 倍（原来的范围），越低越整齐一致，越高差别越大。
    private let spread: Double

    init(seed: UInt64, chaos: CGFloat = 0.5) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
        spread = Double(min(max(chaos, 0.01), 1)) * 2
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// a...b 之间的随机数；随机度改变的是范围的宽窄（中点不变）。原范围全是正数时结果不会小于 a 的三成。
    mutating func range(_ a: Double, _ b: Double) -> Double {
        let mid = (a + b) / 2, half = (b - a) / 2 * spread
        var lo = mid - half
        if a >= 0 { lo = max(lo, a * 0.3) }
        return lo + (mid + half - lo) * next()
    }
}
