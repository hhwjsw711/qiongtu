import SwiftUI

/// 调色里的子面板：局部调色、HSL、肤色调整、色调分离、曲线。左上角返回，右上角重置这一项。
struct AdjustSubPanel: View {
    @Bindable var model: EditorModel
    let sub: AdjustSub

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { model.setAdjustSub(nil) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("返回").font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: reset) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .semibold))
                        Text(sub == .curve ? "重置这条" : "重置").font(.system(size: 14))
                    }
                    .foregroundStyle(changed ? Color.white : Theme.dim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!changed)
            }
            switch sub {
            case .local: LocalSection(model: model)
            case .hsl: HSLSection(model: model)
            case .skin: SkinSection(model: model)
            case .split: SplitSection(model: model)
            case .curve: CurveSection(model: model)
            }
        }
    }

    /// 右上角的重置现在有没有东西可重置。
    private var changed: Bool {
        switch sub {
        case .curve: return model.adjust.curves.isChanged(model.adjust.ui.curveChannel)
        case .local: return !model.adjust.locals.isEmpty
        default: return model.adjust.isChanged(sub)
        }
    }

    private func reset() {
        switch sub {
        case .local:
            model.changeAdjust {
                $0.locals = []
                $0.ui.localID = nil
            }
        case .hsl:
            model.changeAdjust { $0.hsl = $0.hsl.map { _ in SIMD3<Float>(0, 0, 0) } }
        case .skin:
            model.changeAdjust {
                $0[.skinTone] = 0
                $0[.skinWhiten] = 0
            }
        case .split:
            model.changeAdjust { $0.split = SplitTone() }
        case .curve:
            model.changeAdjust { $0.curves.channels[$0.ui.curveChannel] = CurveSet.identity }
        }
    }
}

// MARK: - 通用的小部件

/// 一行：名字 + 滑块 + 数值。
private struct ValueRow: View {
    let title: String
    let value: Float
    var range: ClosedRange<Float> = -1...1
    /// 显示成什么数字，默认是 -100...100。
    var shown: ((Float) -> Int)? = nil
    var onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .frame(width: 52, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value) },
                set: { onChange(Float($0)) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
            Text("\(shown?(value) ?? Int((value * 100).rounded()))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 28)
    }
}

/// 轨道是一条颜色渐变的滑块（色相、饱和度这类"往哪个颜色走"一眼能看出来的）。
private struct TintSlider: View {
    let value: Float
    var range: ClosedRange<Float> = -1...1
    let colors: [Color]
    var onChange: (Float) -> Void

    private let knob: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - knob, 1)
            let span = range.upperBound - range.lowerBound
            let t = CGFloat((value - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 5)
                    .padding(.horizontal, knob / 2 - 2)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: min(max(t, 0), 1) * width)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let x = min(max((drag.location.x - knob / 2) / width, 0), 1)
                        onChange(range.lowerBound + Float(x) * span)
                    }
            )
        }
        .frame(height: 30)
    }
}

/// 名字 + 渐变滑块 + 数值。
private struct TintRow: View {
    let title: String
    let value: Float
    var range: ClosedRange<Float> = -1...1
    let colors: [Color]
    var shown: ((Float) -> Int)? = nil
    var onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .frame(width: 52, alignment: .leading)
            TintSlider(value: value, range: range, colors: colors, onChange: onChange)
            Text("\(shown?(value) ?? Int((value * 100).rounded()))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// 靠近零的时候吸到零，方便回到"没改"。
private func snapped(_ value: Float) -> Float {
    abs(value) < 0.015 ? 0 : value
}

private func color(hue: Double, saturation: Double = 1, brightness: Double = 1) -> Color {
    Color(hue: hue - hue.rounded(.down), saturation: saturation, brightness: brightness)
}

// MARK: - HSL

private struct HSLSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        let selected = model.adjust.ui.hslColor
        let value = model.adjust.hsl[selected.rawValue]
        let hue = selected.hue
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(HSLColor.allCases) { item in
                    Button { model.adjust.ui.hslColor = item } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(color(hue: item.hue, saturation: 0.85, brightness: 0.95))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.white, lineWidth: item == selected ? 2.5 : 0))
                                .overlay {
                                    if item == selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            // 改过的颜色下面有个小点。
                            Circle()
                                .fill(model.adjust.hsl[item.rawValue] != SIMD3<Float>(0, 0, 0) ? Theme.accent : Color.clear)
                                .frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                }
            }
            TintRow(title: "色相", value: value.x,
                    colors: [color(hue: hue - 30.0 / 360), color(hue: hue), color(hue: hue + 30.0 / 360)]) { v in
                update(selected) { $0.x = snapped(v) }
            }
            TintRow(title: "饱和度", value: value.y,
                    colors: [Color(white: 0.5), color(hue: hue)]) { v in
                update(selected) { $0.y = snapped(v) }
            }
            TintRow(title: "明度", value: value.z,
                    colors: [color(hue: hue, brightness: 0.25), color(hue: hue), color(hue: hue, saturation: 0.25)]) { v in
                update(selected) { $0.z = snapped(v) }
            }
        }
    }

    private func update(_ item: HSLColor, _ body: (inout SIMD3<Float>) -> Void) {
        model.changeAdjust { body(&$0.hsl[item.rawValue]) }
    }
}

// MARK: - 肤色调整

private struct SkinSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 8) {
            TintRow(title: "肤色", value: model.adjust[.skinTone],
                    colors: [Color(red: 1.0, green: 0.74, blue: 0.76), Color(red: 0.98, green: 0.8, blue: 0.68),
                             Color(red: 0.98, green: 0.84, blue: 0.56)]) { v in
                model.setAdjust(.skinTone, v)
            }
            ValueRow(title: "白皙", value: model.adjust[.skinWhiten], range: 0...1) { v in
                model.setAdjust(.skinWhiten, v)
            }
        }
    }
}

// MARK: - 色调分离

private struct SplitSection: View {
    @Bindable var model: EditorModel

    private static let rainbow: [Color] = (0...6).map { color(hue: Double($0) / 6, saturation: 0.9) }

    var body: some View {
        let split = model.adjust.split
        VStack(spacing: 6) {
            TintRow(title: "高光色", value: split.highlightHue, range: 0...1, colors: Self.rainbow,
                    shown: { Int(($0 * 360).rounded()) }) { v in
                model.changeAdjust { $0.split.highlightHue = v }
            }
            ValueRow(title: "高光量", value: split.highlightAmount, range: 0...1) { v in
                model.changeAdjust { $0.split.highlightAmount = snapped(v) }
            }
            TintRow(title: "阴影色", value: split.shadowHue, range: 0...1, colors: Self.rainbow,
                    shown: { Int(($0 * 360).rounded()) }) { v in
                model.changeAdjust { $0.split.shadowHue = v }
            }
            ValueRow(title: "阴影量", value: split.shadowAmount, range: 0...1) { v in
                model.changeAdjust { $0.split.shadowAmount = snapped(v) }
            }
            ValueRow(title: "平衡", value: split.balance) { v in
                model.changeAdjust { $0.split.balance = snapped(v) }
            }
        }
    }
}

// MARK: - 曲线

private struct CurveSection: View {
    @Bindable var model: EditorModel

    private static let names = ["全部", "红", "绿", "蓝"]
    private static let tints: [Color] = [.white, Color(red: 1, green: 0.35, blue: 0.35),
                                         Color(red: 0.35, green: 0.9, blue: 0.45), Color(red: 0.4, green: 0.62, blue: 1)]

    var body: some View {
        let channel = model.adjust.ui.curveChannel
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    Chip(title: model.adjust.curves.isChanged(index) ? Self.names[index] + " •" : Self.names[index],
                         selected: channel == index) {
                        model.adjust.ui.curveChannel = index
                    }
                }
                Spacer()
            }
            CurveEditor(points: model.adjust.curves.channels[channel], tint: Self.tints[channel]) { points in
                model.changeAdjust { $0.curves.channels[channel] = points }
            }
            .frame(height: Platform.isMac ? 300 : nil)
        }
    }
}

/// 可以拖的曲线：头尾两个点只能上下动，中间的点可以随便加、拖、删。
private struct CurveEditor: View {
    let points: [CGPoint]
    let tint: Color
    var change: ([CGPoint]) -> Void

    /// 这次手势正在拖哪个点。
    @State private var dragging: Int?
    /// 这次手势里已经把点删掉了，剩下的移动不再理会。
    @State private var finished = false

    private static let limit = 8

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.11))
                Path { path in
                    for i in 1..<4 {
                        let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                .stroke(Color(white: 0.2), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                }
                .stroke(Color(white: 0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Path { path in
                    let shape = CurveShape(points)
                    let steps = 96
                    for i in 0...steps {
                        let x = Double(i) / Double(steps)
                        let p = CGPoint(x: size.width * x, y: size.height * (1 - shape.value(at: x)))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(dragging == index ? Theme.accent : Color.white)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                        .position(x: points[index].x * size.width, y: (1 - points[index].y) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in moved(drag.location, in: size) }
                    .onEnded { _ in
                        dragging = nil
                        finished = false
                    }
            )
        }
        .frame(height: 150)
    }

    private func moved(_ location: CGPoint, in size: CGSize) {
        guard !finished, size.width > 0, size.height > 0 else { return }
        var list = points
        let x = min(max(location.x / size.width, 0), 1)
        let y = min(max(1 - location.y / size.height, 0), 1)
        var index = dragging
        if index == nil {
            // 手指落下：离哪个点近就拖哪个，都不近就在这里加一个。
            func distance(_ p: CGPoint) -> CGFloat {
                hypot(p.x * size.width - location.x, (1 - p.y) * size.height - location.y)
            }
            if let near = list.indices.min(by: { distance(list[$0]) < distance(list[$1]) }), distance(list[near]) < 28 {
                index = near
            } else if list.count < Self.limit, let after = list.firstIndex(where: { $0.x > x }), after > 0,
                      x - list[after - 1].x > 0.04, list[after].x - x > 0.04 {
                list.insert(CGPoint(x: x, y: y), at: after)
                index = after
            } else {
                finished = true
                return
            }
            dragging = index
        }
        guard let i = index, list.indices.contains(i) else { return }
        if i == 0 || i == list.count - 1 {
            list[i].y = y
        } else if location.y < -36 || location.y > size.height + 36 {
            list.remove(at: i)
            dragging = nil
            finished = true
        } else {
            list[i] = CGPoint(x: min(max(x, list[i - 1].x + 0.03), list[i + 1].x - 0.03), y: y)
        }
        change(list)
    }
}

// MARK: - 局部调色

private struct LocalSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            if let point = model.selectedLocal {
                HStack(spacing: 8) {
                    HScroll {
                        HRow(spacing: 8) {
                            ForEach(Array(model.adjust.locals.enumerated()), id: \.element.id) { index, item in
                                Chip(title: item.isNeutral ? "点 \(index + 1)" : "点 \(index + 1) •",
                                     selected: item.id == point.id) {
                                    model.adjust.ui.localID = item.id
                                    model.renderAdjust()
                                }
                            }
                        }
                    }
                    Button { model.removeSelectedLocal() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Theme.chip, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除这个点")
                }
                ValueRow(title: "范围", value: point.radius, range: 0.05...0.6) { v in
                    model.changeSelectedLocal { $0.radius = v }
                }
                ValueRow(title: "亮度", value: point.brightness) { v in
                    model.changeSelectedLocal { $0.brightness = snapped(v) }
                }
                ValueRow(title: "对比度", value: point.contrast) { v in
                    model.changeSelectedLocal { $0.contrast = snapped(v) }
                }
                ValueRow(title: "饱和度", value: point.saturation) { v in
                    model.changeSelectedLocal { $0.saturation = snapped(v) }
                }
                ValueRow(title: "色温", value: point.temperature) { v in
                    model.changeSelectedLocal { $0.temperature = snapped(v) }
                }
                if model.adjust.locals.count >= EditorModel.localLimit {
                    Text("已经放满 \(EditorModel.localLimit) 个点了")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accent)
                    Text("点一下照片放调节点")
                        .font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            }
        }
    }
}
