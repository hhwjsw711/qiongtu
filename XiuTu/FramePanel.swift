import SwiftUI
import UIKit

extension FrameColor {
    var color: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: 1) }

    /// 从系统取色器拿到的颜色（超出 sRGB 的部分会被收回来）。
    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: r, g: g, b: b)
    }
}

/// 一排颜色：最前面是自选颜色（系统取色器），后面是常用色。
struct FrameColorRow: View {
    let selected: FrameColor
    var pick: (FrameColor) -> Void

    static let common: [FrameColor] = [
        .white, FrameColor(hex: 0x0A0A0A), FrameColor(hex: 0xF6F2EA), FrameColor(hex: 0xECEDEF),
        FrameColor(hex: 0x8E8E93), FrameColor(hex: 0x2B2B2E), FrameColor(hex: 0xF4C7C3), FrameColor(hex: 0xF9E0B0),
        FrameColor(hex: 0xCDE7C9), FrameColor(hex: 0xBFE3F2), FrameColor(hex: 0xC9C6F0), FrameColor(hex: 0xE85D5D),
        FrameColor(hex: 0xF2A33A), FrameColor(hex: 0x3A7BD5), FrameColor(hex: 0x2E5E4E), FrameColor(hex: 0x1F2A44),
        FrameColor(hex: 0x6B4A3A),
    ]

    var body: some View {
        HScroll {
            HRow(spacing: 8) {
                FrameColorWell(color: selected, pick: pick)
                ForEach(Self.common, id: \.self) { item in
                    Button { pick(item) } label: {
                        Circle()
                            .fill(item.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().stroke(selected == item ? Theme.accent : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .frame(height: 36)
    }
}

/// 自选颜色的小圆钮（点开是系统取色器）。
struct FrameColorWell: View {
    let color: FrameColor
    var pick: (FrameColor) -> Void

    var body: some View {
        ColorPicker("", selection: Binding(get: { color.color }, set: { pick(FrameColor($0)) }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 32, height: 32)
    }
}

/// 数值 + 滑块的一行。
struct FrameSliderRow: View {
    let value: CGFloat
    var range: ClosedRange<Double> = 0...1
    var text: String? = nil
    var set: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text ?? "\(Int((value * 100).rounded()))")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }), in: range)
        }
        .frame(height: 36)
    }
}

// MARK: - 边框

/// 边框面板：上面一排样式（用当前照片画的缩略图），下面调颜色、粗细、圆角。
struct FramePanel: View {
    @Bindable var model: EditorModel

    private enum Tab { case color, backing, width, radius }

    @State private var tab: Tab = .color
    @State private var editingCaption = false
    @State private var draft = ""

    var body: some View {
        let params = model.frameState.frame
        VStack(spacing: 10) {
            HScroll {
                HRow(alignment: .top, spacing: 10) {
                    ForEach(FramePreset.all) { preset in
                        ImageTile(title: preset.title, image: model.frameState.thumbs[preset.id],
                                  selected: model.frameState.presetID == preset.id, symbol: "photo.artframe") {
                            model.selectFramePreset(preset)
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)

            if params.style != .none {
                options(params)
                control(params)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .alert("边框上的字", isPresented: $editingCaption) {
            TextField("比如：2026.11 东京", text: $draft)
            Button("确定") {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                model.updateFrame { $0.caption = text }
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 当前样式下实际用的那个标签（比如从邮票换到白边后，"底色"就没有了）。
    private func current(_ params: FrameParams) -> Tab {
        tab == .backing && !params.style.hasBacking ? .color : tab
    }

    private func options(_ params: FrameParams) -> some View {
        let now = current(params)
        return HScroll {
            HRow(spacing: 8) {
                Chip(title: params.style.hasBacking ? "纸色" : "颜色", selected: now == .color) { tab = .color }
                if params.style.hasBacking {
                    Chip(title: "底色", selected: now == .backing) { tab = .backing }
                }
                Chip(title: params.style == .line ? "位置" : "粗细", selected: now == .width) { tab = .width }
                Chip(title: "圆角", selected: now == .radius) { tab = .radius }
                if params.style.hasCaption || params.style.canGoInside {
                    Rectangle().fill(Theme.chip).frame(width: 1, height: 20)
                }
                if params.style.hasCaption {
                    Chip(title: params.caption.isEmpty ? "写字" : "改字", symbol: "textformat", selected: false) {
                        draft = params.caption
                        editingCaption = true
                    }
                }
                if params.style.canGoInside {
                    Chip(title: "向内", symbol: "arrow.down.right.and.arrow.up.left", selected: params.inside) {
                        model.updateFrame { $0.inside.toggle() }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    @ViewBuilder
    private func control(_ params: FrameParams) -> some View {
        switch current(params) {
        case .color:
            FrameColorRow(selected: params.color) { picked in model.updateFrame { $0.color = picked } }
        case .backing:
            FrameColorRow(selected: params.backing) { picked in model.updateFrame { $0.backing = picked } }
        case .width:
            FrameSliderRow(value: params.width) { value in model.updateFrame { $0.width = value } }
        case .radius:
            FrameSliderRow(value: params.radius) { value in
                model.updateFrame { $0.radius = value < 0.02 ? 0 : value }
            }
        }
    }
}

// MARK: - 背景

/// 背景面板：选画布比例和背景的填充方式，再调照片在画布里的大小、位置、圆角和投影。
struct BackdropPanel: View {
    @Bindable var model: EditorModel

    private enum Key: String, Identifiable {
        case scale, radius, shadow, moveX, moveY, blur, dim, pattern, angle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .scale: return "大小"
            case .radius: return "圆角"
            case .shadow: return "投影"
            case .moveX: return "左右"
            case .moveY: return "上下"
            case .blur: return "模糊"
            case .dim: return "压暗"
            case .pattern: return "图案大小"
            case .angle: return "方向"
            }
        }

        var symbol: String {
            switch self {
            case .scale: return "arrow.up.left.and.arrow.down.right"
            case .radius: return "app"
            case .shadow: return "shadow"
            case .moveX: return "arrow.left.and.right"
            case .moveY: return "arrow.up.and.down"
            case .blur: return "drop"
            case .dim: return "moon"
            case .pattern: return "circle.grid.3x3"
            case .angle: return "rotate.right"
            }
        }
    }

    @State private var key: Key = .scale

    /// 渐变的现成配色。
    private static let gradients: [(FrameColor, FrameColor)] = [
        (FrameColor(hex: 0xFDFBFB), FrameColor(hex: 0xEBEDEE)), (FrameColor(hex: 0xF5F7FA), FrameColor(hex: 0xC3CFE2)),
        (FrameColor(hex: 0xFFECD2), FrameColor(hex: 0xFCB69F)), (FrameColor(hex: 0xFBC2EB), FrameColor(hex: 0xA6C1EE)),
        (FrameColor(hex: 0xA1C4FD), FrameColor(hex: 0xC2E9FB)), (FrameColor(hex: 0xD4FC79), FrameColor(hex: 0x96E6A1)),
        (FrameColor(hex: 0xFA709A), FrameColor(hex: 0xFEE140)), (FrameColor(hex: 0x30CFD0), FrameColor(hex: 0x330867)),
        (FrameColor(hex: 0x232526), FrameColor(hex: 0x414345)),
    ]

    /// 图案的现成配色：底色 + 图案色。
    private static let patterns: [(FrameColor, FrameColor)] = [
        (FrameColor(hex: 0xFFF4E0), FrameColor(hex: 0xF2B5A0)), (FrameColor(hex: 0xBFE3F2), FrameColor(hex: 0xFFFFFF)),
        (FrameColor(hex: 0xF7F7F7), FrameColor(hex: 0xDADADA)), (FrameColor(hex: 0xFDE2E4), FrameColor(hex: 0xFFFFFF)),
        (FrameColor(hex: 0xE2ECE9), FrameColor(hex: 0xBEE1E6)), (FrameColor(hex: 0x1F2A44), FrameColor(hex: 0xE8C547)),
        (FrameColor(hex: 0x222222), FrameColor(hex: 0x3A3A3A)),
    ]

    var body: some View {
        let params = model.frameState.backdrop
        let now = current(params)
        VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 8) {
                    ForEach(BackdropRatio.allCases) { ratio in
                        Chip(title: ratio.title, selected: params.ratio == ratio) {
                            model.updateBackdrop { $0.ratio = ratio }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)

            HScroll {
                HRow(spacing: 8) {
                    ForEach(BackdropFill.allCases) { fill in
                        Chip(title: fill.title, symbol: fill.symbol, selected: params.fill == fill) {
                            model.updateBackdropFill { $0.fill = fill }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)

            fillRow(params)
            slider(params, key: now)
            HScroll {
                HRow(spacing: 4) {
                    ForEach(keys(params)) { item in
                        IconTile(symbol: item.symbol, title: item.title, selected: item == now,
                                 modified: changed(item, params)) { key = item }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, -16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func keys(_ params: BackdropParams) -> [Key] {
        var list: [Key] = [.scale, .radius, .shadow, .moveX, .moveY]
        switch params.fill {
        case .blur: list += [.blur, .dim]
        case .gradient: list += [.angle]
        case .checks, .dots, .stripes: list += [.pattern]
        case .solid: break
        }
        return list
    }

    /// 换了填充方式后，原来选的那一项可能没有了，退回"大小"。
    private func current(_ params: BackdropParams) -> Key {
        keys(params).contains(key) ? key : .scale
    }

    private func changed(_ key: Key, _ p: BackdropParams) -> Bool {
        let base = BackdropParams()
        switch key {
        case .scale: return p.scale < 0.999
        case .radius: return p.radius > 0
        case .shadow: return p.shadow > 0
        case .moveX: return p.offset.x != 0
        case .moveY: return p.offset.y != 0
        case .blur: return p.blur != base.blur
        case .dim: return p.dim != base.dim
        case .pattern: return p.pattern != base.pattern
        case .angle: return p.angle != base.angle
        }
    }

    @ViewBuilder
    private func fillRow(_ params: BackdropParams) -> some View {
        switch params.fill {
        case .blur:
            Color.clear.frame(height: 36)
        case .solid:
            FrameColorRow(selected: params.colorA) { picked in model.updateBackdropFill { $0.colorA = picked } }
        case .gradient:
            pairRow(params, pairs: Self.gradients, gradient: true)
        case .checks, .dots, .stripes:
            pairRow(params, pairs: Self.patterns, gradient: false)
        }
    }

    /// 两个自选颜色 + 一排现成配色。
    private func pairRow(_ params: BackdropParams, pairs: [(FrameColor, FrameColor)], gradient: Bool) -> some View {
        HStack(spacing: 8) {
            FrameColorWell(color: params.colorA) { picked in model.updateBackdropFill { $0.colorA = picked } }
            FrameColorWell(color: params.colorB) { picked in model.updateBackdropFill { $0.colorB = picked } }
            Rectangle().fill(Theme.chip).frame(width: 1, height: 20)
            HScroll {
                HRow(spacing: 8) {
                    ForEach(pairs.indices, id: \.self) { index in
                        let pair = pairs[index]
                        let on = params.colorA == pair.0 && params.colorB == pair.1
                        Button {
                            model.updateBackdropFill { $0.colorA = pair.0; $0.colorB = pair.1 }
                        } label: {
                            swatch(pair, gradient: gradient)
                                .frame(width: 40, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color(white: 0.4), lineWidth: 1))
                                .padding(3)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(on ? Theme.accent : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 16)
            }
            .padding(.trailing, -16)
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func swatch(_ pair: (FrameColor, FrameColor), gradient: Bool) -> some View {
        if gradient {
            LinearGradient(colors: [pair.0.color, pair.1.color], startPoint: .top, endPoint: .bottom)
        } else {
            HStack(spacing: 0) {
                pair.0.color
                pair.1.color
            }
        }
    }

    @ViewBuilder
    private func slider(_ p: BackdropParams, key: Key) -> some View {
        switch key {
        case .scale:
            FrameSliderRow(value: p.scale, range: 0.4...1) { value in
                model.updateBackdrop { $0.scale = value > 0.99 ? 1 : value }
            }
        case .radius:
            FrameSliderRow(value: p.radius) { value in model.updateBackdrop { $0.radius = value < 0.02 ? 0 : value } }
        case .shadow:
            FrameSliderRow(value: p.shadow) { value in model.updateBackdrop { $0.shadow = value < 0.02 ? 0 : value } }
        case .moveX:
            FrameSliderRow(value: p.offset.x, range: -1...1) { value in
                model.updateBackdrop { $0.offset.x = abs(value) < 0.03 ? 0 : value }
            }
        case .moveY:
            FrameSliderRow(value: p.offset.y, range: -1...1) { value in
                model.updateBackdrop { $0.offset.y = abs(value) < 0.03 ? 0 : value }
            }
        case .blur:
            FrameSliderRow(value: p.blur) { value in model.updateBackdrop { $0.blur = value } }
        case .dim:
            FrameSliderRow(value: p.dim) { value in model.updateBackdrop { $0.dim = value } }
        case .pattern:
            FrameSliderRow(value: p.pattern) { value in model.updateBackdrop { $0.pattern = value } }
        case .angle:
            FrameSliderRow(value: p.angle, range: 0...360, text: "\(Int(p.angle.rounded()))°") { value in
                // 每 45° 吸附一下，方便对齐横平竖直。
                let snapped = (value / 45).rounded() * 45
                model.updateBackdrop { $0.angle = abs(value - snapped) < 4 ? snapped : value }
            }
        }
    }
}
