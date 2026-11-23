import SwiftUI

/// 形状面板：加方块、圆、多边形、星形、箭头、气泡……，改颜色、描边、阴影、大小和边角。
/// 形状和文字、贴纸一样浮在照片上面，AI 修图不会把它画进照片里。
struct GraphicPanel: View {
    @Bindable var model: EditorModel

    private enum Tab: String, CaseIterable, Identifiable {
        case kind, color, stroke, shadow, size, corner

        var id: String { rawValue }

        var title: String {
            switch self {
            case .kind: return "形状"
            case .color: return "颜色"
            case .stroke: return "描边"
            case .shadow: return "阴影"
            case .size: return "大小"
            case .corner: return "边角"
            }
        }
    }

    @State private var tab: Tab = .kind

    private var selected: OverlayItem? { model.selectedOverlay.flatMap { $0.isGraphic ? $0 : nil } }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { model.addGraphic(selected?.graphic?.kind ?? .rect) } label: {
                    Label("形状", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                HScroll {
                    HRow(spacing: 18) {
                        ForEach(Tab.allCases) { item in tabButton(item) }
                    }
                    .padding(.trailing, 8)
                }
            }
            Group {
                if tab == .kind {
                    kinds
                } else if let item = selected {
                    content(item)
                } else {
                    Color.clear
                }
            }
            .frame(height: 128, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .onAppear {
            // 进来时还没有形状就先放一条横条，直接就能拖、能改。
            if !model.overlayItems.contains(where: { $0.isGraphic }) { model.addGraphic(.rect) }
        }
    }

    private func tabButton(_ item: Tab) -> some View {
        let on = tab == item
        return Button { tab = item } label: {
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: on ? .bold : .regular))
                    .foregroundStyle(on ? Color.white : Theme.dim)
                Capsule().fill(on ? Theme.accent : Color.clear).frame(width: 16, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func change(_ body: (inout OverlayItem) -> Void) {
        guard let id = selected?.id else { return }
        model.updateOverlay(id, body)
    }

    private func changeGraphic(_ body: (inout GraphicStyle) -> Void) {
        change { item in
            guard var g = item.graphic else { return }
            body(&g)
            item.graphic = g
        }
    }

    /// 选中了形状就换它的种类，没选中就加一个新的。
    private var kinds: some View {
        HScroll {
            HRow(spacing: 10) {
                ForEach(GraphicKind.allCases) { kind in
                    let on = selected?.graphic?.kind == kind
                    Button {
                        if selected != nil {
                            change { item in
                                guard var g = item.graphic else { return }
                                g.kind = kind
                                if kind == .star { g.sides = max(g.sides, 5) }
                                if kind != .rect, g.aspect < 0.35 {
                                    // 从细长的横条换成别的形状：比例和大小都换成这个形状合适的。
                                    g.aspect = kind == .arrow ? 0.45 : 1
                                    item.size = 0.35 / max(item.scale, 0.01)
                                }
                                item.graphic = g
                            }
                        } else {
                            model.addGraphic(kind)
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 26))
                                .foregroundStyle(on ? Theme.accent : Color.white)
                                .frame(width: 64, height: 56)
                                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(on ? Theme.accent : Color.clear, lineWidth: 2))
                            Text(kind.title)
                                .font(.system(size: 12))
                                .foregroundStyle(on ? Theme.accent : Color.white)
                        }
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func content(_ item: OverlayItem) -> some View {
        let g = item.graphic ?? GraphicStyle()
        switch tab {
        case .kind:
            EmptyView()
        case .color:
            VStack(spacing: 12) {
                // "无"= 不填充，只留描边。
                OverlayColorRow(selected: g.fill ? item.color : nil, allowsNone: true) { color in
                    change { i in
                        if let color {
                            i.color = color
                            i.graphic?.fill = true
                        } else {
                            i.graphic?.fill = false
                            if !i.strokeOn { i.strokeOn = true; i.strokeColor = i.color }
                        }
                    }
                }
                MiniSlider(title: "不透明度", value: item.opacity, range: 0.05...1, labelWidth: 56) { v in change { $0.opacity = v } }
            }
        case .stroke:
            VStack(spacing: 12) {
                OverlayColorRow(selected: item.strokeOn ? item.strokeColor : nil, allowsNone: true) { color in
                    change { i in
                        if let color {
                            i.strokeOn = true
                            i.strokeColor = color
                        } else {
                            i.strokeOn = false
                            i.graphic?.fill = true
                        }
                    }
                }
                MiniSlider(title: "粗细", value: item.strokeWidth, range: 0.05...1) { v in
                    change { $0.strokeOn = true; $0.strokeWidth = v }
                }
            }
        case .shadow:
            VStack(spacing: 10) {
                OverlayColorRow(selected: item.shadowOn ? item.shadowColor : nil, allowsNone: true) { color in
                    change { i in
                        if let color {
                            i.shadowOn = true
                            i.shadowColor = color
                        } else {
                            i.shadowOn = false
                        }
                    }
                }
                HStack(spacing: 14) {
                    MiniSlider(title: "虚实", value: item.shadowBlur, range: 0...1) { v in change { $0.shadowOn = true; $0.shadowBlur = v } }
                    MiniSlider(title: "距离", value: item.shadowDistance, range: 0...1) { v in change { $0.shadowOn = true; $0.shadowDistance = v } }
                }
                HStack(spacing: 14) {
                    MiniSlider(title: "角度", value: item.shadowAngle, range: 0...360) { v in change { $0.shadowOn = true; $0.shadowAngle = v } }
                    MiniSlider(title: "浓度", value: item.shadowOpacity, range: 0.1...1) { v in change { $0.shadowOn = true; $0.shadowOpacity = v } }
                }
            }
        case .size:
            VStack(spacing: 14) {
                MiniSlider(title: "宽", value: item.size * item.scale, range: 0.03...1.4) { v in
                    change { $0.size = v / max($0.scale, 0.01) }
                }
                // 高按"高 / 宽"调，滑条用对数刻度：细长的字幕条和瘦高的竖条都好调。
                MiniSlider(title: "高", value: log2(max(g.aspect, 0.05)), range: -4.3...2) { v in
                    changeGraphic { $0.aspect = pow(2, v) }
                }
            }
            .padding(.top, 8)
        case .corner:
            VStack(spacing: 12) {
                if g.kind != .ellipse && g.kind != .heart {
                    MiniSlider(title: "圆角", value: g.corner, range: 0...1) { v in changeGraphic { $0.corner = v } }
                }
                if g.kind == .rect {
                    HStack(spacing: 10) {
                        MiniSlider(title: "切角", value: g.cut, range: 0...0.5) { v in changeGraphic { $0.cut = v } }
                        ForEach([(1, "左上"), (2, "右上"), (8, "左下"), (4, "右下")], id: \.0) { bit, title in
                            Chip(title: title, selected: g.cutCorners & bit != 0) {
                                changeGraphic { s in
                                    s.cutCorners ^= bit
                                    if s.cut == 0, s.cutCorners & bit != 0 { s.cut = 0.25 }
                                }
                            }
                        }
                    }
                }
                if g.kind == .polygon || g.kind == .star {
                    MiniSlider(title: g.kind == .star ? "角数" : "边数", value: CGFloat(g.sides),
                               range: g.kind == .star ? 4...12 : 3...12) { v in
                        changeGraphic { $0.sides = Int(v.rounded()) }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}
