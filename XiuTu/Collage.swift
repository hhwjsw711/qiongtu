import CoreGraphics
import CoreImage
import Foundation

// 这个文件只用 Core Image / CoreGraphics，不依赖 UIKit，方便单独拿出来验证拼出来的图。

/// 拼图画布的比例。
enum CollageRatio: String, CaseIterable, Identifiable {
    case r3x4, r1x1, r4x3, r4x5, r2x3, r3x2, r9x16, r16x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .r3x4: return "3:4"
        case .r1x1: return "1:1"
        case .r4x3: return "4:3"
        case .r4x5: return "4:5"
        case .r2x3: return "2:3"
        case .r3x2: return "3:2"
        case .r9x16: return "9:16"
        case .r16x9: return "16:9"
        }
    }

    /// 宽 / 高。
    var value: CGFloat {
        switch self {
        case .r3x4: return 3.0 / 4
        case .r1x1: return 1
        case .r4x3: return 4.0 / 3
        case .r4x5: return 4.0 / 5
        case .r2x3: return 2.0 / 3
        case .r3x2: return 3.0 / 2
        case .r9x16: return 9.0 / 16
        case .r16x9: return 16.0 / 9
        }
    }
}

/// 拼图里用到的颜色（背景、间隔）。
struct CollageColor: Equatable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    var ciColor: CIColor { CIColor(red: r, green: g, blue: b) }

    static let white = CollageColor(r: 1, g: 1, b: 1)

    static let palette: [CollageColor] = [
        .white,
        CollageColor(r: 0, g: 0, b: 0),
        CollageColor(r: 0.93, g: 0.93, b: 0.93),
        CollageColor(r: 0.96, g: 0.93, b: 0.86),
        CollageColor(r: 0.99, g: 0.86, b: 0.88),
        CollageColor(r: 0.84, g: 0.91, b: 0.98),
        CollageColor(r: 0.85, g: 0.93, b: 0.85),
        CollageColor(r: 0.99, g: 0.93, b: 0.70),
        CollageColor(r: 0.20, g: 0.22, b: 0.26),
    ]
}

/// 模板的切法：一格，或者横着 / 竖着按比例切成几块，可以嵌套。
indirect enum CollageSplit {
    case cell
    case h([(CGFloat, CollageSplit)])
    case v([(CGFloat, CollageSplit)])

    /// 横着排的几格，参数是各格的宽度比例。
    static func cols(_ weights: CGFloat...) -> CollageSplit { .h(weights.map { ($0, .cell) }) }

    /// 竖着排的几格，参数是各格的高度比例。
    static func rows(_ weights: CGFloat...) -> CollageSplit { .v(weights.map { ($0, .cell) }) }

    static func grid(rows: Int, cols: Int) -> CollageSplit {
        .v((0..<rows).map { _ in (1, .h((0..<cols).map { _ in (1, .cell) })) })
    }

    /// 切出来的每一格，归一化坐标，原点左上角。
    func rects(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [CGRect] {
        switch self {
        case .cell:
            return [rect]
        case .h(let parts):
            let total = parts.reduce(0) { $0 + $1.0 }
            var x = rect.minX
            var out: [CGRect] = []
            for (weight, part) in parts {
                let w = rect.width * weight / total
                out += part.rects(in: CGRect(x: x, y: rect.minY, width: w, height: rect.height))
                x += w
            }
            return out
        case .v(let parts):
            let total = parts.reduce(0) { $0 + $1.0 }
            var y = rect.minY
            var out: [CGRect] = []
            for (weight, part) in parts {
                let h = rect.height * weight / total
                out += part.rects(in: CGRect(x: rect.minX, y: y, width: rect.width, height: h))
                y += h
            }
            return out
        }
    }
}

/// 一个拼图模板：画布被切成几格。
struct CollageLayout: Identifiable, Equatable {
    let id: String
    /// 每一格在画布里的位置，归一化坐标，原点左上角。
    let cells: [CGRect]
    /// 从第几格开始是叠在上面的"画中画"小格；等于 cells.count 表示没有。
    let insetFrom: Int
    /// 最适合的画布比例（"全部"里按这个比例显示）。
    let natural: CollageRatio

    static func == (a: CollageLayout, b: CollageLayout) -> Bool { a.id == b.id }

    /// 这个模板放在这种比例的画布上会不会切出太细长的格子。
    func fits(_ ratio: CollageRatio) -> Bool {
        for cell in cells.prefix(insetFrom) {
            let aspect = cell.width * ratio.value / cell.height
            if aspect > 3.3 || aspect < 1 / 3.3 { return false }
        }
        return true
    }

    private static func make(_ id: String, _ natural: CollageRatio, _ split: CollageSplit,
                             insets: [CGRect] = []) -> CollageLayout {
        let base = split.rects()
        return CollageLayout(id: id, cells: base + insets, insetFrom: base.count, natural: natural)
    }

    private static let big: CollageSplit = .h([(2, .cell), (1, .rows(1, 1))])

    /// 全部模板，按格子数从少到多。
    static let all: [CollageLayout] = [
        // 2 格
        make("2h", .r1x1, .cols(1, 1)),
        make("2v", .r3x4, .rows(1, 1)),
        make("2h21", .r4x3, .cols(2, 1)),
        make("2h12", .r4x3, .cols(1, 2)),
        make("2v21", .r3x4, .rows(2, 1)),
        make("2v12", .r3x4, .rows(1, 2)),
        make("2pip", .r3x4, .cell, insets: [CGRect(x: 0.24, y: 0.3, width: 0.52, height: 0.4)]),
        // 3 格
        make("3h", .r3x2, .cols(1, 1, 1)),
        make("3v", .r2x3, .rows(1, 1, 1)),
        make("3l", .r1x1, .h([(1, .cell), (1, .rows(1, 1))])),
        make("3r", .r1x1, .h([(1, .rows(1, 1)), (1, .cell)])),
        make("3t", .r3x4, .v([(1, .cell), (1, .cols(1, 1))])),
        make("3b", .r3x4, .v([(1, .cols(1, 1)), (1, .cell)])),
        make("3l2", .r4x3, big),
        make("3t2", .r3x4, .v([(2, .cell), (1, .cols(1, 1))])),
        make("3pip", .r3x4, .rows(1, 1), insets: [CGRect(x: 0.27, y: 0.34, width: 0.46, height: 0.32)]),
        // 4 格
        make("4g", .r1x1, .grid(rows: 2, cols: 2)),
        make("4h", .r16x9, .cols(1, 1, 1, 1)),
        make("4v", .r9x16, .rows(1, 1, 1, 1)),
        make("4l", .r4x3, .h([(2, .cell), (1, .rows(1, 1, 1))])),
        make("4t", .r3x4, .v([(2, .cell), (1, .cols(1, 1, 1))])),
        make("4b", .r3x4, .v([(1, .cols(1, 1, 1)), (2, .cell)])),
        make("4m", .r3x4, .v([(1, .cols(1, 1)), (1, .cols(1, 2))])),
        // 5 格
        make("5a", .r3x4, .v([(1, .cols(1, 1)), (1, .cols(1, 1, 1))])),
        make("5b", .r3x4, .v([(1, .cols(1, 1, 1)), (1, .cols(1, 1))])),
        make("5c", .r4x3, .h([(1, .rows(1, 1)), (1, .rows(1, 1, 1))])),
        make("5d", .r4x3, .h([(1, .cell), (1, .grid(rows: 2, cols: 2))])),
        make("5e", .r3x4, .v([(2, .cell), (1, .cols(1, 1)), (1, .cols(1, 1))])),
        make("5pip", .r1x1, .grid(rows: 2, cols: 2), insets: [CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)]),
        // 6 格
        make("6a", .r3x4, .grid(rows: 3, cols: 2)),
        make("6b", .r4x3, .grid(rows: 2, cols: 3)),
        make("6c", .r1x1, .v([(2, big), (1, .cols(1, 1, 1))])),
        make("6d", .r3x4, .v([(1, .cols(1, 1, 1)), (2, .cols(1, 1)), (1, .cell)])),
        // 7 格
        make("7a", .r3x4, .v([(1, .cols(1, 1)), (1, .cols(1, 1, 1)), (1, .cols(1, 1))])),
        make("7b", .r1x1, .v([(2, big), (1, .cols(1, 1, 1, 1))])),
        // 8 格
        make("8a", .r3x4, .v([(1, .cols(1, 1, 1)), (1, .cols(1, 1)), (1, .cols(1, 1, 1))])),
        make("8b", .r3x4, .grid(rows: 4, cols: 2)),
        // 9 格
        make("9a", .r1x1, .grid(rows: 3, cols: 3)),
        make("9b", .r3x4, .v([(2, big), (1, .cols(1, 1, 1)), (1, .cols(1, 1, 1))])),
    ]

    /// 一个模板最多能放几张图。
    static let maxCells = all.map(\.cells.count).max() ?? 9
}

/// 拼图里的一张图，以及它在格子里怎么摆。
struct CollagePicture: Identifiable {
    var id = UUID()
    /// true = 正在编辑的这张图（渲染时再传进来）；false = 从相册加进来的图，存在 image 里。
    var isBase = false
    /// 从相册加进来的图，导入时已经摆正并缩到长边 3072 以内。
    var image: CGImage?
    /// 实时预览用的小图。
    var small: CGImage?
    /// 模板里图片在格子内的平移：-1...1，对应"铺满格子后多出来的部分"的两头。
    var offset = CGPoint.zero
    /// 模板里图片在格子内的放大倍数，1 = 刚好铺满。
    var zoom: CGFloat = 1
    var flip = false
    /// 顺时针转了几个 90°。
    var quarterTurns = 0
    /// 拼接时沿拼接方向裁掉的比例：开头（竖拼 = 上面，横拼 = 左边）和结尾。
    var cropStart: CGFloat = 0
    var cropEnd: CGFloat = 0

    /// 拼接时留下的比例。
    var keep: CGFloat { max(1 - cropStart - cropEnd, 0.05) }
}

/// 拼图：把当前这张图和另外几张图拼成一张，作为编辑历史里的一步。
/// 所有尺寸都按画布大小折算，预览图和原图导出拼出来的样子一致。
struct CollageParams {
    enum Mode: String, CaseIterable, Identifiable {
        case template, stitch

        var id: String { rawValue }

        var title: String { self == .template ? "模板" : "拼接" }
    }

    var mode: Mode = .template
    /// 拼进来的图，按顺序放进格子（模板）或者依次接起来（拼接）。
    var pictures: [CollagePicture] = [CollagePicture(isBase: true)]

    // 模板
    var layout = CollageLayout.all[0]
    var ratio: CollageRatio = .r1x1
    /// 格子之间的间距、四周的边距、格子的圆角，都相对于画布短边。
    var gap: CGFloat = 0.012
    var margin: CGFloat = 0.012
    var corner: CGFloat = 0
    var background = CollageColor.white

    // 拼接
    /// true = 竖拼（上下接），false = 横拼（左右接）。
    var vertical = true
    /// 拼接时图与图之间的间隔，相对于图的宽（竖拼）或高（横拼）；0 = 无缝。
    var stitchGap: CGFloat = 0

    /// 模板最长边的上限。
    static let maxTemplateSide: CGFloat = 8000
    /// 拼接长图的上限：最长边和总像素。只卡 8000 的话，十来张图拼下来宽度只剩几百像素，没法看，
    /// 所以导出放到 20000 / 3600 万像素；屏幕上的实时预览用小得多的上限。
    static let maxStitchSide: CGFloat = 20000
    static let maxStitchPixels: CGFloat = 36_000_000
    static let previewStitchSide: CGFloat = 8000
    static let previewStitchPixels: CGFloat = 10_000_000

    /// 只有正在编辑的这一张、没加别的图：等于没拼。
    var isIdentity: Bool {
        pictures.isEmpty || (pictures.count == 1 && pictures[0].isBase
            && (mode == .template || (pictures[0].cropStart == 0 && pictures[0].cropEnd == 0)))
    }

    /// 模板里放不下的图有几张。
    var hiddenCount: Int {
        mode == .template ? max(0, pictures.count - layout.cells.count) : 0
    }

    // MARK: 排版

    /// 第 index 张图摆正之后的尺寸。reference = 正在编辑的图的尺寸。
    func pictureSize(_ index: Int, reference: CGSize) -> CGSize {
        let p = pictures[index]
        var size = reference
        if !p.isBase, let image = p.image {
            size = CGSize(width: image.width, height: image.height)
        }
        if p.quarterTurns % 2 != 0 { size = CGSize(width: size.height, height: size.width) }
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// 拼接时每张图沿拼接方向的"自然长度"（没裁过的整张）：以另一边为 1。
    func stitchFullLengths(reference: CGSize) -> [CGFloat] {
        pictures.indices.map { i in
            let s = pictureSize(i, reference: reference)
            return vertical ? s.height / s.width : s.width / s.height
        }
    }

    /// 拼接时每张图裁过之后沿拼接方向的长度。
    private func stitchLengths(reference: CGSize) -> [CGFloat] {
        zip(stitchFullLengths(reference: reference), pictures).map { $0 * $1.keep }
    }

    /// 拼出来的画布有多大（像素）。reference = 正在编辑的图的尺寸，决定输出的清晰度。
    /// preview = true 时长图按预览的上限算；排版比例不受影响。
    func canvasSize(reference: CGSize, preview: Bool = false) -> CGSize {
        switch mode {
        case .template:
            let long = min(max(reference.width, reference.height, 16), Self.maxTemplateSide)
            let r = ratio.value
            let size = r >= 1 ? CGSize(width: long, height: long / r) : CGSize(width: long * r, height: long)
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        case .stitch:
            let lengths = stitchLengths(reference: reference)
            let cross = max(vertical ? reference.width : reference.height, 16)
            let total = (lengths.reduce(0, +) + stitchGap * CGFloat(max(lengths.count - 1, 0))) * cross
            var k: CGFloat = 1
            k = min(k, (preview ? Self.previewStitchSide : Self.maxStitchSide) / max(cross, total))
            k = min(k, ((preview ? Self.previewStitchPixels : Self.maxStitchPixels) / max(cross * total, 1)).squareRoot())
            let a = max((cross * k).rounded(), 2)
            let b = max((total * k).rounded(), 2)
            return vertical ? CGSize(width: a, height: b) : CGSize(width: b, height: a)
        }
    }

    /// 每一格（模板）或每一张图（拼接）在画布里的位置，原点左上角。
    /// canvas 可以是输出的像素尺寸，也可以是屏幕上显示的尺寸，算出来的比例一样。
    func frames(canvas: CGSize, reference: CGSize) -> [CGRect] {
        switch mode {
        case .template:
            let short = min(canvas.width, canvas.height)
            let m = margin * short
            let half = gap * short / 2
            let inner = CGRect(x: m, y: m, width: canvas.width - m * 2, height: canvas.height - m * 2)
            return layout.cells.enumerated().map { index, cell in
                var x0 = inner.minX + cell.minX * inner.width
                var x1 = inner.minX + cell.maxX * inner.width
                var y0 = inner.minY + cell.minY * inner.height
                var y1 = inner.minY + cell.maxY * inner.height
                if index < layout.insetFrom {
                    // 贴着画布边的那一侧不留间距，只有格子之间留。
                    if cell.minX > 0.001 { x0 += half }
                    if cell.maxX < 0.999 { x1 -= half }
                    if cell.minY > 0.001 { y0 += half }
                    if cell.maxY < 0.999 { y1 -= half }
                }
                x0 = x0.rounded(); x1 = x1.rounded(); y0 = y0.rounded(); y1 = y1.rounded()
                return CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
            }
        case .stitch:
            let lengths = stitchLengths(reference: reference)
            guard !lengths.isEmpty else { return [] }
            let along = vertical ? canvas.height : canvas.width
            let cross = vertical ? canvas.width : canvas.height
            let count = CGFloat(lengths.count)
            let natural = lengths.reduce(0, +) + stitchGap * (count - 1)
            // 画布的长度是取整过的，这里按比例摊回去，相邻两张共用同一条取整后的边，中间不会漏缝。
            let unit = along / max(natural, 0.0001)
            var out: [CGRect] = []
            var cursor: CGFloat = 0
            for (i, length) in lengths.enumerated() {
                let start = (cursor * unit).rounded()
                cursor += length
                let end = i == lengths.count - 1 ? along : (cursor * unit).rounded()
                cursor += stitchGap
                out.append(vertical
                    ? CGRect(x: 0, y: start, width: cross, height: max(end - start, 1))
                    : CGRect(x: start, y: 0, width: max(end - start, 1), height: cross))
            }
            return out
        }
    }

    /// 模板里第 index 张图铺满它的格子之后，横竖各多出来多少（和 cell 同一个单位）。拖动图片时用。
    func fillExcess(_ index: Int, cell: CGSize, reference: CGSize) -> CGSize {
        let size = pictureSize(index, reference: reference)
        let s = max(cell.width / size.width, cell.height / size.height) * max(pictures[index].zoom, 1)
        return CGSize(width: max(size.width * s - cell.width, 0), height: max(size.height * s - cell.height, 0))
    }

    // MARK: 渲染

    /// image 是当前正在编辑的图（拼图里 isBase 的那一张）。
    func apply(to image: CIImage) -> CIImage {
        render(base: image, preview: false)
    }

    /// preview = true：实时预览，用小图、用快的缩放方式，并且把空格子画成浅灰色。
    func render(base: CIImage, preview: Bool) -> CIImage {
        let baseImage = Self.atOrigin(base)
        guard !isIdentity || preview else { return baseImage }
        let reference = baseImage.extent.size
        let canvas = canvasSize(reference: reference, preview: preview)
        let rects = frames(canvas: canvas, reference: reference)
        let bounds = CGRect(origin: .zero, size: canvas)
        var out = CIImage(color: background.ciColor).cropped(to: bounds)

        func source(_ index: Int) -> CIImage? {
            let p = pictures[index]
            var img: CIImage
            if p.isBase {
                img = baseImage
            } else if let cg = (preview ? p.small : nil) ?? p.image {
                img = CIImage(cgImage: cg)
            } else {
                return nil
            }
            return Self.oriented(img, turns: p.quarterTurns, flip: p.flip)
        }

        switch mode {
        case .template:
            let short = min(canvas.width, canvas.height)
            let radius = corner * short
            for (index, rect) in rects.enumerated() {
                let target = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
                if index >= layout.insetFrom {
                    // 画中画的小格外面留一圈背景色的边，和底下的图分开。
                    let border = max(gap * short, short * 0.004)
                    let frame = target.insetBy(dx: -border, dy: -border)
                    out = Self.shape(frame, radius: radius > 0 ? radius + border : 0, color: background.ciColor)
                        .composited(over: out)
                }
                if index < pictures.count, let img = source(index) {
                    let p = pictures[index]
                    out = Self.fill(img, into: target, offset: p.offset, zoom: p.zoom, radius: radius, hq: !preview)
                        .composited(over: out)
                } else if preview {
                    out = Self.shape(target, radius: radius, color: CIColor(red: 0.84, green: 0.84, blue: 0.86))
                        .composited(over: out)
                }
            }
        case .stitch:
            for (index, rect) in rects.enumerated() {
                guard var img = source(index) else { continue }
                // 沿拼接方向裁掉两头（Core Image 的 y 朝上：竖拼时"上面"在 y 大的那头）。
                let p = pictures[index]
                if p.cropStart > 0 || p.cropEnd > 0 {
                    let e = img.extent
                    let keepRect = vertical
                        ? CGRect(x: e.minX, y: e.minY + e.height * p.cropEnd, width: e.width, height: e.height * p.keep)
                        : CGRect(x: e.minX + e.width * p.cropStart, y: e.minY, width: e.width * p.keep, height: e.height)
                    img = Self.atOrigin(img.cropped(to: keepRect.integral))
                }
                let target = CGRect(x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
                out = Self.fill(img, into: target, offset: .zero, zoom: 1, radius: 0, hq: !preview)
                    .composited(over: out)
            }
        }
        return out.cropped(to: bounds)
    }

    /// 把图的原点挪回 (0,0)。
    private static func atOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.minX != 0 || e.minY != 0 else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    /// 先水平翻转，再顺时针转 turns 个 90°，原点回到 (0,0)。
    private static func oriented(_ image: CIImage, turns: Int, flip: Bool) -> CIImage {
        let n = ((turns % 4) + 4) % 4
        guard n != 0 || flip else { return image }
        var t = CGAffineTransform.identity
        if flip { t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        // Core Image 的 y 轴朝上，顺时针转是负角度。
        if n != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: -CGFloat(n) * .pi / 2)) }
        return atOrigin(image.transformed(by: t))
    }

    /// 一块纯色的（圆角）矩形。
    private static func shape(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let r = min(radius, min(rect.width, rect.height) / 2)
        if r > 0.5, let rounded = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": r,
            "inputColor": color,
        ])?.outputImage {
            return rounded.cropped(to: rect)
        }
        return CIImage(color: color).cropped(to: rect)
    }

    /// 把图铺满 target（Core Image 坐标），多出来的部分按 offset 取舍，再按圆角裁掉四个角。
    private static func fill(_ image: CIImage, into target: CGRect, offset: CGPoint, zoom: CGFloat,
                             radius: CGFloat, hq: Bool) -> CIImage {
        let e = image.extent
        guard e.width >= 1, e.height >= 1, target.width >= 1, target.height >= 1 else {
            return CIImage.empty()
        }
        let s = max(target.width / e.width, target.height / e.height) * max(zoom, 1)
        // 先把边缘像素向外延伸再缩放：不然缩放会把图外面的透明混进最边上一圈，拼接的接缝处就会透出背景色。
        let endless = image.clampedToExtent()
        var scaled: CIImage
        if hq, s < 0.999 {
            scaled = endless.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: s,
                kCIInputAspectRatioKey: 1.0,
            ])
        } else {
            scaled = endless.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        // 两种缩放都以原点为中心，缩放后图片实际占的范围：
        let se = CGRect(x: e.minX * s, y: e.minY * s, width: e.width * s, height: e.height * s)
        let ex = max(e.width * s - target.width, 0)
        let ey = max(e.height * s - target.height, 0)
        let ox = min(max(offset.x, -1), 1)
        let oy = min(max(offset.y, -1), 1)
        // offset.y 是屏幕方向（向下为正），Core Image 的 y 朝上，所以反过来。
        let cx = target.midX + ox * ex / 2
        let cy = target.midY - oy * ey / 2
        scaled = scaled.transformed(by: CGAffineTransform(translationX: (cx - se.midX).rounded(),
                                                          y: (cy - se.midY).rounded()))
        var placed = scaled.cropped(to: target)
        let r = min(radius, min(target.width, target.height) / 2)
        if r > 0.5 {
            placed = placed.applyingFilter("CISourceInCompositing", parameters: [
                kCIInputBackgroundImageKey: shape(target, radius: r, color: CIColor(red: 1, green: 1, blue: 1)),
            ]).cropped(to: target)
        }
        return placed
    }
}
