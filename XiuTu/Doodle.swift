import CoreGraphics
import CoreImage
import Foundation

/// 涂鸦用的颜色（sRGB，0...1）。
struct DoodleColor: Equatable, Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    static let white = DoodleColor(r: 1, g: 1, b: 1)
    static let black = DoodleColor(r: 0, g: 0, b: 0)
    static let red = DoodleColor(r: 1, g: 0.27, b: 0.27)

    /// 面板上的色板：前面是常用色，后面几个是画妆容用的。
    static let palette: [DoodleColor] = [
        .white, .black, .red,
        DoodleColor(r: 1.0, g: 0.58, b: 0.0),
        DoodleColor(r: 1.0, g: 0.84, b: 0.04),
        DoodleColor(r: 0.2, g: 0.82, b: 0.35),
        DoodleColor(r: 0.2, g: 0.78, b: 0.9),
        DoodleColor(r: 0.04, g: 0.52, b: 1.0),
        DoodleColor(r: 0.69, g: 0.32, b: 0.87),
        DoodleColor(r: 1.0, g: 0.45, b: 0.7),
        DoodleColor(r: 0.2, g: 0.13, b: 0.09),
        DoodleColor(r: 0.45, g: 0.3, b: 0.2),
        DoodleColor(r: 0.72, g: 0.36, b: 0.38),
        DoodleColor(r: 0.86, g: 0.3, b: 0.45),
        DoodleColor(r: 0.95, g: 0.5, b: 0.45),
        DoodleColor(r: 0.93, g: 0.7, b: 0.66),
    ]

    func cg(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.62 }

    /// t = 0 是自己，t = 1 是 other。
    func mixed(with other: DoodleColor, _ t: CGFloat) -> DoodleColor {
        DoodleColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// 色相 0...1，饱和度和亮度拉满。
    static func hue(_ h: CGFloat) -> DoodleColor {
        let x = (h - h.rounded(.down)) * 6
        let i = Int(x) % 6
        let f = x - CGFloat(Int(x))
        switch i {
        case 0: return DoodleColor(r: 1, g: f, b: 0)
        case 1: return DoodleColor(r: 1 - f, g: 1, b: 0)
        case 2: return DoodleColor(r: 0, g: 1, b: f)
        case 3: return DoodleColor(r: 0, g: 1 - f, b: 1)
        case 4: return DoodleColor(r: f, g: 0, b: 1)
        default: return DoodleColor(r: 1, g: 0, b: 1 - f)
        }
    }
}

/// 涂鸦面板里画笔的分组。
enum DoodleCategory: String, CaseIterable, Identifiable {
    case pen, makeup, pattern

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "画笔"
        case .makeup: return "妆容"
        case .pattern: return "图案"
        }
    }

    var brushes: [DoodleBrush] { DoodleBrush.allCases.filter { $0.category == self } }
}

/// 所有画笔。前三组是手绘（跟着手指走的线），mark 那一组是"标记"里拖出来的形状（起点 + 终点）。
enum DoodleBrush: String, CaseIterable, Identifiable {
    case pen, arrowPen, marker, highlighter, pencil, calligraphy, crayon, cloud, spray, dashed, rainbow, neon
    case brow, eyeliner, eyeshadow, blush, lip, glow
    case stars, hearts, sparkles, bubbles, petals, leaves, raindrops, snowflakes, notes
    case arrow, line, rect, ellipse, bar, number, spot
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "圆头笔"
        case .arrowPen: return "箭头笔"
        case .marker: return "马克笔"
        case .highlighter: return "荧光笔"
        case .pencil: return "铅笔"
        case .calligraphy: return "毛笔"
        case .crayon: return "蜡笔"
        case .cloud: return "云朵"
        case .spray: return "喷枪"
        case .dashed: return "虚线"
        case .rainbow: return "彩虹"
        case .neon: return "霓虹"
        case .brow: return "眉笔"
        case .eyeliner: return "眼线"
        case .eyeshadow: return "眼影"
        case .blush: return "腮红"
        case .lip: return "口红"
        case .glow: return "高光"
        case .stars: return "星星"
        case .hearts: return "爱心"
        case .sparkles: return "闪光"
        case .bubbles: return "泡泡"
        case .petals: return "樱花"
        case .leaves: return "落叶"
        case .raindrops: return "雨滴"
        case .snowflakes: return "雪花"
        case .notes: return "音符"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .rect: return "方框"
        case .ellipse: return "圆圈"
        case .bar: return "高亮"
        case .number: return "序号"
        case .spot: return "聚光"
        case .eraser: return "橡皮"
        }
    }

    /// nil = 不出现在涂鸦的画笔列表里（标记形状和橡皮）。
    var category: DoodleCategory? {
        switch self {
        case .pen, .arrowPen, .marker, .highlighter, .pencil, .calligraphy, .crayon, .cloud, .spray, .dashed, .rainbow, .neon:
            return .pen
        case .brow, .eyeliner, .eyeshadow, .blush, .lip, .glow:
            return .makeup
        case .stars, .hearts, .sparkles, .bubbles, .petals, .leaves, .raindrops, .snowflakes, .notes:
            return .pattern
        default:
            return nil
        }
    }

    /// "标记"里的形状：由起点和终点两个点决定。
    var isShape: Bool {
        switch self {
        case .arrow, .line, .rect, .ellipse, .bar, .number, .spot: return true
        default: return false
        }
    }

    static let shapes: [DoodleBrush] = [.arrow, .line, .rect, .ellipse, .bar, .number, .spot]

    /// 标记面板上的图标。
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .bar: return "highlighter"
        case .number: return "1.circle"
        case .spot: return "circle.dashed"
        default: return "scribble.variable"
        }
    }

    /// 实际线宽 = 面板上的"大小" × 这个倍数。不同画笔手感差得多，同一个滑块值下各自放大到合适的粗细。
    var widthFactor: CGFloat {
        switch self {
        case .pen, .arrowPen, .dashed, .rainbow, .line, .rect, .ellipse, .arrow: return 1
        case .pencil: return 0.6
        case .eyeliner: return 0.7
        case .brow: return 0.9
        case .neon: return 0.9
        case .calligraphy: return 1.6
        case .marker: return 1.8
        case .highlighter: return 2.6
        case .crayon: return 2.2
        case .lip: return 1.6
        case .cloud, .spray: return 3.2
        case .eyeshadow, .glow: return 3.5
        case .blush: return 7
        case .stars, .hearts, .sparkles, .bubbles, .petals, .leaves, .raindrops, .snowflakes, .notes: return 3.2
        case .bar: return 1
        case .number: return 1
        case .spot: return 1
        case .eraser: return 2.5
        }
    }

    /// 选中这支笔时"浓度"滑块的默认值。
    var defaultOpacity: CGFloat {
        switch self {
        case .highlighter: return 0.45
        case .marker: return 0.9
        case .brow: return 0.5
        case .eyeliner: return 0.75
        case .eyeshadow: return 0.45
        case .blush: return 0.35
        case .lip: return 0.55
        case .glow: return 0.4
        case .bar: return 0.4
        default: return 1
        }
    }

    /// 选中这支笔时自动换成的颜色；nil = 保持当前颜色。
    var defaultColor: DoodleColor? {
        switch self {
        case .brow: return DoodleColor(r: 0.2, g: 0.13, b: 0.09)
        case .eyeliner: return .black
        case .eyeshadow: return DoodleColor(r: 0.72, g: 0.36, b: 0.38)
        case .blush: return DoodleColor(r: 0.95, g: 0.5, b: 0.45)
        case .lip: return DoodleColor(r: 0.86, g: 0.3, b: 0.45)
        case .glow: return .white
        case .petals: return DoodleColor(r: 1.0, g: 0.72, b: 0.8)
        case .leaves: return DoodleColor(r: 0.9, g: 0.48, b: 0.15)
        case .raindrops: return DoodleColor(r: 0.72, g: 0.88, b: 1.0)
        case .snowflakes: return .white
        default: return nil
        }
    }

    /// 画笔列表缩略图上用的颜色。
    var sampleColor: DoodleColor {
        switch self {
        case .arrowPen: return .red
        case .highlighter: return DoodleColor(r: 1.0, g: 0.84, b: 0.04)
        case .marker: return DoodleColor(r: 1.0, g: 0.58, b: 0.0)
        case .pencil: return DoodleColor(r: 0.12, g: 0.12, b: 0.12)
        case .calligraphy: return DoodleColor(r: 0.08, g: 0.08, b: 0.08)
        case .crayon: return DoodleColor(r: 0.2, g: 0.78, b: 0.9)
        case .neon: return DoodleColor(r: 1.0, g: 0.3, b: 0.75)
        case .dashed: return DoodleColor(r: 0.2, g: 0.82, b: 0.35)
        case .stars: return DoodleColor(r: 1.0, g: 0.84, b: 0.04)
        case .hearts: return DoodleColor(r: 1.0, g: 0.35, b: 0.5)
        case .sparkles: return DoodleColor(r: 0.55, g: 0.8, b: 1.0)
        case .bubbles: return DoodleColor(r: 0.6, g: 0.9, b: 1.0)
        case .notes: return DoodleColor(r: 1.0, g: 0.84, b: 0.04)
        default: return defaultColor ?? .white
        }
    }
}

/// 一笔。点是归一化的图片坐标（原点左上角），粗细以图片长边为 1。
struct DoodleStroke: Equatable {
    var brush: DoodleBrush
    /// 手绘：手指经过的点；形状：[起点, 终点]；序号：[位置]。
    var points: [CGPoint]
    var width: CGFloat
    var color: DoodleColor
    /// 整笔的不透明度（一笔之内自己叠到自己不会变深）。
    var opacity: CGFloat = 1
    /// 这一笔的随机数种子：喷枪、蜡笔、星星这些带随机散布的笔，预览和导出用同一个种子，画出来才一样。
    var seed: UInt64 = 0
    /// 序号圆点上的数字。
    var number = 0
    /// 图案笔的随机分布；nil = 默认值。
    var jitter: DoodleJitter? = nil
    /// 妆容笔只画在这些范围里（五官）。每一项是一块：第一圈是外轮廓，后面的是挖掉的洞。归一化坐标。
    var region: [[[CGPoint]]] = []
    /// 范围边缘的羽化宽度（以图片长边为 1）。
    var feather: CGFloat = 0
}

/// 图案笔的随机分布（像 Photoshop 画笔的散布、间距、大小抖动）。
struct DoodleJitter: Equatable {
    /// 间距：相邻两个图案隔多远，按笔的粗细算。
    var spacing: CGFloat = 1.25
    /// 散布：图案离开手指路线多远，按笔的粗细算。
    var scatter: CGFloat = 0.35
    /// 大小随机 0...1。
    var size: CGFloat = 0.5
    /// 角度随机 0...1（1 = 随便转）。
    var angle: CGFloat = 0.2
    /// 每个落点放几个图案。
    var count: CGFloat = 1
}

/// 涂鸦 / 标记：画在图上的笔画，作为编辑历史里的一步。
struct DoodleParams: Equatable {
    let strokes: [DoodleStroke]
    /// 只用来认"是不是同一份笔画"，好复用已经画好的那一层。
    private let stamp = UUID()

    init(strokes: [DoodleStroke] = []) {
        self.strokes = strokes
    }

    static func == (a: DoodleParams, b: DoodleParams) -> Bool { a.strokes == b.strokes }

    /// 只有橡皮擦的笔画等于什么都没画。
    var isIdentity: Bool { !strokes.contains { $0.brush != .eraser } }

    func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !isIdentity, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        // 笔画先画成一张透明的位图再叠上去。图特别大时位图按长边 4096 画，再放大，够清楚也不占太多内存。
        let k = min(1, DoodleRenderer.maxLayerSide / max(extent.width, extent.height))
        let w = max(1, Int((extent.width * k).rounded()))
        let h = max(1, Int((extent.height * k).rounded()))
        let layer = DoodleRenderer.cachedLayer(key: "\(stamp.uuidString)-\(w)x\(h)", strokes: strokes, width: w, height: h)
        return DoodleRenderer.compose(over: image, layers: layer.map { [($0, 1)] } ?? [],
                                      spots: strokes.filter { $0.brush == .spot })
    }
}
