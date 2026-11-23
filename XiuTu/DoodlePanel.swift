import SwiftUI
import UIKit

extension DoodleColor {
    var color: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: 1) }

    init(_ color: Color) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
    }
}

/// 画笔列表上的示意图：每支笔画一条波浪线，只算一次。
@MainActor
enum DoodleThumbs {
    private static var cache: [DoodleBrush: UIImage] = [:]

    static func image(for brush: DoodleBrush) -> UIImage? {
        if let hit = cache[brush] { return hit }
        guard let cg = DoodleRenderer.sample(brush, width: 216, height: 132) else { return nil }
        let image = UIImage(cgImage: cg, scale: 3, orientation: .up)
        cache[brush] = image
        return image
    }
}

/// 一排颜色：最前面是自选颜色（系统取色器，里面带吸管），后面是常用色。
struct DoodleColorRow: View {
    @Binding var color: DoodleColor

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("自选颜色", selection: Binding(get: { color.color }, set: { color = DoodleColor($0) }),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30, height: 30)
            HScroll {
                HRow(spacing: 10) {
                    ForEach(DoodleColor.palette, id: \.self) { item in
                        Button { color = item } label: {
                            Circle()
                                .fill(item.color)
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().stroke(color == item ? Theme.accent : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
                .padding(.horizontal, 1)
            }
        }
    }
}

/// 面板上的小圆按钮（撤销、重做、橡皮、清空）。
private struct DoodleRoundButton: View {
    let symbol: String
    var active = false
    var enabled = true
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.black : Color.white)
                .frame(width: 32, height: 32)
                .background(active ? Theme.accent : Theme.chip, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct DoodleSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
            Slider(value: $value, in: range)
        }
    }
}

/// 涂鸦面板：选画笔、颜色、大小和浓度，直接在图上画。
struct DoodlePanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let state = model.doodleState
        VStack(spacing: 10) {
            if let note = state.note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
            }
            HStack(spacing: 5) {
                ForEach(DoodleCategory.allCases) { category in
                    Chip(title: category.title, selected: state.category == category) {
                        model.doodleState.category = category
                    }
                }
                Spacer(minLength: 4)
                DoodleRoundButton(symbol: "arrow.uturn.backward", enabled: state.canUndo, label: "撤销一笔") {
                    model.doodleUndoStroke()
                }
                DoodleRoundButton(symbol: "arrow.uturn.forward", enabled: state.canRedo, label: "重做") {
                    model.doodleRedoStroke()
                }
                DoodleRoundButton(symbol: "eraser", active: state.erasing, label: "橡皮") {
                    model.doodleState.erasing.toggle()
                }
                DoodleRoundButton(symbol: "trash", enabled: state.canUndo, label: "全部清掉") {
                    model.doodleClear()
                }
            }
            HStack(spacing: 12) {
                DoodleSlider(title: "大小", value: $model.doodleState.size, range: 2...40)
                DoodleSlider(title: "浓度", value: $model.doodleState.opacity, range: 0.1...1)
                    .opacity(state.erasing ? 0.35 : 1)
                    .disabled(state.erasing)
                Button { model.setDoodleSmooth(!state.smooth) } label: {
                    Text("圆润")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(state.smooth ? Color.black : Color.white)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(state.smooth ? Theme.accent : Theme.chip, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if state.category == .pattern {
                HStack(alignment: .top, spacing: 10) {
                    DoodleRoundButton(symbol: "slider.horizontal.3", active: state.showJitter, label: "图案分布") {
                        model.doodleState.showJitter.toggle()
                    }
                    if state.showJitter {
                        jitterSliders
                    } else {
                        DoodleColorRow(color: $model.doodleState.color)
                    }
                }
            } else {
                DoodleColorRow(color: $model.doodleState.color)
            }
            HScroll {
                HRow(alignment: .top, spacing: 8) {
                    ForEach(state.category.brushes) { brush in
                        brushTile(brush, selected: !state.erasing && state.brush == brush)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, -16)
            .id(state.category)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// 图案笔的分布：间距、散布、大小差、角度、数量。
    private var jitterSliders: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                DoodleSlider(title: "间距", value: $model.doodleState.jitter.spacing, range: 0.3...4)
                DoodleSlider(title: "散布", value: $model.doodleState.jitter.scatter, range: 0...3)
            }
            HStack(spacing: 12) {
                DoodleSlider(title: "大小差", value: $model.doodleState.jitter.size, range: 0...1)
                DoodleSlider(title: "角度", value: $model.doodleState.jitter.angle, range: 0...1)
                DoodleSlider(title: "数量", value: $model.doodleState.jitter.count, range: 1...5)
            }
        }
    }

    private func brushTile(_ brush: DoodleBrush, selected: Bool) -> some View {
        Button { model.selectDoodleBrush(brush) } label: {
            VStack(spacing: 5) {
                ZStack {
                    tileBackground(brush)
                    if let image = DoodleThumbs.image(for: brush) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                .frame(width: 72, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5)
                )
                Text(brush.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressStyle())
    }

    /// 妆容笔垫一块肤色，深色的笔垫灰底，其余垫深色，示意线才看得清。
    private func tileBackground(_ brush: DoodleBrush) -> Color {
        if brush.category == .makeup { return Color(red: 0.93, green: 0.78, blue: 0.69) }
        let c = brush.sampleColor
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b < 0.3 ? Color(white: 0.5) : Color(white: 0.16)
    }
}

/// 标记面板：箭头、方框、圆圈、序号这类标注，在图上拖出来。
struct MarkPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let state = model.doodleState
        VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 2) {
                    ForEach(DoodleBrush.shapes) { shape in
                        IconTile(symbol: shape.symbol, title: shape.title, selected: state.brush == shape) {
                            model.selectDoodleBrush(shape)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            HStack(spacing: 6) {
                DoodleSlider(title: state.brush == .number ? "大小" : "粗细", value: $model.doodleState.size, range: 2...20)
                    .opacity(state.brush == .bar || state.brush == .spot ? 0.35 : 1)
                    .disabled(state.brush == .bar || state.brush == .spot)
                DoodleRoundButton(symbol: "arrow.uturn.backward", enabled: state.canUndo, label: "撤销一步") {
                    model.doodleUndoStroke()
                }
                DoodleRoundButton(symbol: "arrow.uturn.forward", enabled: state.canRedo, label: "重做") {
                    model.doodleRedoStroke()
                }
                DoodleRoundButton(symbol: "trash", enabled: state.canUndo, label: "全部清掉") {
                    model.doodleClear()
                }
            }
            DoodleColorRow(color: $model.doodleState.color)
                .opacity(state.brush == .spot ? 0.35 : 1)
                .disabled(state.brush == .spot)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}
