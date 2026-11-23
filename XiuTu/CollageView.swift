import PhotosUI
import SwiftUI

/// 拼图时的画布：显示拼好的样子。
/// 模板：点空格子加图，点图选中，拖动挪图在格子里的位置，双指放大，长按后拖到别的格子换位置。
/// 拼接：可以滚动和双指缩放，末尾总有一个"添加图片"的空位。
struct CollageCanvas: View {
    @Bindable var model: EditorModel

    @State private var stitchZoom: CGFloat = 1
    @State private var zoomStart: CGFloat?
    /// 推拼接的边：按下时的图和每个单位在屏幕上多长。
    @State private var pushStart: (pictures: [CollagePicture], unit: CGFloat)?

    static let space = "collageCanvas"

    var body: some View {
        GeometryReader { geo in
            let params = model.collageState.params
            let reference = model.collageReference
            let canvas = params.canvasSize(reference: reference, preview: true)
            Group {
                if params.mode == .template {
                    template(geo.size, canvas: canvas, reference: reference)
                } else {
                    stitch(geo.size, canvas: canvas, reference: reference)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay {
            if model.collageState.loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(22)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    /// 实时预览是在后台算出来的，换模板的那一瞬间手上还是上一张图；比例对不上就先不显示，免得被拉变形。
    @ViewBuilder
    private func picture(_ size: CGSize, canvas: CGSize) -> some View {
        let wanted = canvas.width / max(canvas.height, 1)
        if let image = model.displayImage, image.size.height > 0,
           abs(image.size.width / image.size.height - wanted) < wanted * 0.02 {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        } else {
            Color(white: 0.12).frame(width: size.width, height: size.height)
        }
    }

    // MARK: 模板

    private func template(_ box: CGSize, canvas: CGSize, reference: CGSize) -> some View {
        let fitted = aspectFit(canvas, in: CGSize(width: box.width - 24, height: box.height - 24))
        let frames = model.collageState.params.frames(canvas: fitted, reference: reference)
        return ZStack {
            picture(fitted, canvas: canvas)
            ForEach(frames.indices, id: \.self) { index in
                CollageCellOverlay(model: model, index: index, frame: frames[index], frames: frames, reference: reference)
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .coordinateSpace(name: Self.space)
        .position(x: box.width / 2, y: box.height / 2)
    }

    // MARK: 拼接

    private func stitch(_ box: CGSize, canvas: CGSize, reference: CGSize) -> some View {
        let params = model.collageState.params
        let vertical = params.vertical
        let aspect = max(canvas.width, 1) / max(canvas.height, 1)
        // 末尾"添加图片"的空位沿拼接方向占多长。
        let slot: CGFloat = 104
        // 没放大时：图少就整条放进屏幕；图多了，宽度（竖拼）或高度（横拼）也不小于屏幕的一半多，剩下的靠滚动。
        var size: CGSize
        if vertical {
            let widest = max(box.width - 32, 40)
            let fit = (box.height - 40 - slot) * aspect
            let w = min(widest, max(fit, widest * 0.55)) * stitchZoom
            size = CGSize(width: w, height: w / aspect)
        } else {
            let tallest = max(box.height - 32, 40)
            let fit = (box.width - 40 - slot) / aspect
            let h = min(tallest, max(fit, tallest * 0.5)) * stitchZoom
            size = CGSize(width: h * aspect, height: h)
        }
        let empty = params.pictures.isEmpty
        if empty { size = vertical ? CGSize(width: size.width, height: 0) : CGSize(width: 0, height: size.height) }
        let frames = params.frames(canvas: size, reference: reference)
        let selected = model.collageState.selected
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        let cross = vertical ? max(size.width, 120) : max(size.height, 120)

        return ScrollView([.horizontal, .vertical], showsIndicators: false) {
            layout {
                if !empty {
                    ZStack {
                        picture(size, canvas: canvas)
                        ForEach(frames.indices, id: \.self) { index in
                            Rectangle()
                                .stroke(selected == index ? Theme.accent : Color.clear, lineWidth: 2.5)
                                .frame(width: frames[index].width, height: frames[index].height)
                                .contentShape(Rectangle())
                                .onTapGesture { model.collageTap(index) }
                                .position(x: frames[index].midX, y: frames[index].midY)
                        }
                        ForEach(stitchHandles(frames, vertical: vertical), id: \.edge) { handle in
                            pushHandle(handle, vertical: vertical, size: size, reference: reference)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                }
                Button { model.collageRequestAdd() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 24))
                        Text("添加图片").font(.system(size: 12))
                    }
                    .foregroundStyle(Color(white: 0.6))
                    .frame(width: vertical ? cross : slot, height: vertical ? slot : cross)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(white: 0.45), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
            .padding(16)
            .frame(minWidth: box.width, minHeight: box.height)
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if zoomStart == nil { zoomStart = stitchZoom }
                    stitchZoom = min(max((zoomStart ?? 1) * value.magnification, 0.5), 3)
                }
                .onEnded { _ in zoomStart = nil }
        )
    }
}

extension CollageCanvas {
    struct StitchHandle {
        let edge: StitchEdge
        let point: CGPoint
    }

    /// 每条可以推的边放一个把手：第一张的开头、每两张之间、最后一张的结尾。
    func stitchHandles(_ frames: [CGRect], vertical: Bool) -> [StitchHandle] {
        guard let first = frames.first, let last = frames.last else { return [] }
        var out: [StitchHandle] = []
        out.append(StitchHandle(edge: .start, point: vertical ? CGPoint(x: first.midX, y: first.minY + 14)
                                                              : CGPoint(x: first.minX + 14, y: first.midY)))
        for i in 0..<(frames.count - 1) {
            let a = frames[i]
            out.append(StitchHandle(edge: .seam(i), point: vertical ? CGPoint(x: a.midX, y: a.maxY)
                                                                     : CGPoint(x: a.maxX, y: a.midY)))
        }
        out.append(StitchHandle(edge: .end, point: vertical ? CGPoint(x: last.midX, y: last.maxY - 14)
                                                            : CGPoint(x: last.maxX - 14, y: last.midY)))
        return out
    }

    func pushHandle(_ handle: StitchHandle, vertical: Bool, size: CGSize, reference: CGSize) -> some View {
        let symbol: String
        switch handle.edge {
        case .start: symbol = vertical ? "arrow.up" : "arrow.left"
        case .seam: symbol = vertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right"
        case .end: symbol = vertical ? "arrow.down" : "arrow.right"
        }
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: vertical ? 46 : 26, height: vertical ? 26 : 46)
            .background(Theme.accent, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .frame(width: 60, height: 44)
            .contentShape(Rectangle())
            .position(handle.point)
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if pushStart == nil {
                            // 屏幕上一个单位（图的宽 / 高）有多长：按下那一刻量一次，拖动中画布变长变短也不跟着变。
                            let full = model.collageState.params.stitchFullLengths(reference: reference)
                            let kept = zip(full, model.collageState.params.pictures).map { $0 * $1.keep }.reduce(0, +)
                            let gap = model.collageState.params.stitchGap * CGFloat(max(full.count - 1, 0))
                            let along = vertical ? size.height : size.width
                            pushStart = (model.collageState.params.pictures, along / max(kept + gap, 0.0001))
                        }
                        guard let start = pushStart else { return }
                        let t = vertical ? value.translation.height : value.translation.width
                        model.collageStitchPush(handle.edge, moved: t / max(start.unit, 0.0001), from: start.pictures)
                    }
                    .onEnded { _ in pushStart = nil }
            )
    }
}

/// 模板里一格的交互层：盖在拼好的图上面，本身是透明的。
private struct CollageCellOverlay: View {
    let model: EditorModel
    let index: Int
    let frame: CGRect
    let frames: [CGRect]
    let reference: CGSize

    @State private var panStart: CGPoint?
    @State private var zoomStart: CGFloat?
    @GestureState private var swapActive = false

    private var filled: Bool { index < model.collageState.params.pictures.count }

    var body: some View {
        let state = model.collageState
        let isFilled = index < state.params.pictures.count
        ZStack {
            if isFilled {
                Rectangle().fill(state.swapFrom == index ? Color.black.opacity(0.4) : Color.clear)
                if state.swapTo == index, state.swapFrom != nil, state.swapFrom != index {
                    Rectangle().fill(Theme.accent.opacity(0.35))
                }
                Rectangle().stroke(state.selected == index ? Theme.accent : Color.clear, lineWidth: 2.5)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: min(24, max(12, frame.width * 0.28))))
                    if frame.width > 76, frame.height > 64 {
                        Text("添加图片").font(.system(size: 11))
                    }
                }
                .foregroundStyle(Color(white: 0.42))
                Rectangle().stroke(Color(white: 0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .onTapGesture { model.collageTap(index) }
        .gesture(pan, including: isFilled ? .all : .subviews)
        .simultaneousGesture(zoom, including: isFilled ? .all : .subviews)
        .simultaneousGesture(swap, including: isFilled ? .all : .subviews)
        .onChange(of: swapActive) { _, active in
            // 手势结束或被打断（比如落下第二根手指）都会走到这里，把"正在换位置"的标记清掉。
            if !active, model.collageState.swapFrom == index {
                model.collageState.swapFrom = nil
                model.collageState.swapTo = nil
            }
        }
        .position(x: frame.midX, y: frame.midY)
    }

    /// 拖动：挪图在格子里的位置。
    private var pan: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard filled, model.collageState.swapFrom == nil else { return }
                if panStart == nil {
                    panStart = model.collageState.params.pictures[index].offset
                    if model.collageState.selected != index { model.collageState.selected = index }
                }
                guard let start = panStart else { return }
                let excess = model.collageState.params.fillExcess(index, cell: frame.size, reference: reference)
                var offset = start
                if excess.width > 0.5 { offset.x = start.x + value.translation.width * 2 / excess.width }
                if excess.height > 0.5 { offset.y = start.y + value.translation.height * 2 / excess.height }
                model.collagePan(index, to: offset)
            }
            .onEnded { _ in panStart = nil }
    }

    /// 双指：放大这一格里的图。
    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard filled else { return }
                if zoomStart == nil {
                    zoomStart = model.collageState.params.pictures[index].zoom
                    if model.collageState.selected != index { model.collageState.selected = index }
                }
                model.collageZoom(index, to: (zoomStart ?? 1) * value.magnification)
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// 长按后拖到另一格：两格的图换位置。
    private var swap: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(CollageCanvas.space)))
            .updating($swapActive) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard filled, case .second(true, let drag) = value else { return }
                if model.collageState.swapFrom != index {
                    model.collageState.swapFrom = index
                    model.collageState.swapTo = nil
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                if let drag {
                    let target = cell(at: drag.location)
                    if model.collageState.swapTo != target { model.collageState.swapTo = target }
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value, let target = cell(at: drag.location), target != index else { return }
                model.collageSwap(index, target)
            }
    }

    /// 这个位置落在哪一格有图的格子上（画中画的小格在上面，优先）。
    private func cell(at point: CGPoint) -> Int? {
        let count = model.collageState.params.pictures.count
        return frames.indices.reversed().first { $0 < count && frames[$0].contains(point) }
    }
}

/// 模板的小图标：按模板的切法画出来。
struct CollageLayoutIcon: View {
    let layout: CollageLayout
    let ratio: CGFloat
    let selected: Bool

    var body: some View {
        Canvas { context, size in
            let box = aspectFit(CGSize(width: ratio, height: 1), in: CGSize(width: size.width - 14, height: size.height - 14))
            let origin = CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2)
            let line = selected ? Theme.accent : Color(white: 0.75)
            for (index, cell) in layout.cells.enumerated() {
                let rect = CGRect(x: origin.x + cell.minX * box.width, y: origin.y + cell.minY * box.height,
                                  width: cell.width * box.width, height: cell.height * box.height)
                    .insetBy(dx: 1.1, dy: 1.1)
                let path = Path(roundedRect: rect, cornerRadius: 2.2)
                // 画中画的小格先填上底色，把底下那格的线盖住。
                if index >= layout.insetFrom { context.fill(path, with: .color(Color(white: 0.16))) }
                context.stroke(path, with: .color(line), lineWidth: 1.5)
            }
        }
        .frame(width: 52, height: 52)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1.5)
        )
    }
}

/// 拼图面板：模板 / 拼接。选中某一张图时换成这张图的操作。
struct CollagePanel: View {
    @Bindable var model: EditorModel

    @State private var page: Page = .layout
    @State private var styleKey: StyleKey = .gap

    private enum Page { case layout, style }

    private enum StyleKey: String, CaseIterable, Identifiable {
        case gap, corner, margin

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gap: return "间距"
            case .corner: return "圆角"
            case .margin: return "边距"
            }
        }

        var symbol: String {
            switch self {
            case .gap: return "square.split.2x2"
            case .corner: return "app"
            case .margin: return "rectangle.inset.filled"
            }
        }

        /// 滑块拉满对应的数值（相对于画布短边）。
        var limit: CGFloat {
            switch self {
            case .gap: return 0.06
            case .corner: return 0.12
            case .margin: return 0.08
            }
        }
    }

    private let rows = [GridItem(.fixed(52), spacing: 6), GridItem(.fixed(52), spacing: 6)]

    var body: some View {
        let state = model.collageState
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                SegmentBar(items: CollageParams.Mode.allCases, selected: state.params.mode,
                           title: { $0.title },
                           symbol: { $0 == .template ? "rectangle.split.2x2" : "rectangle.split.1x2" }) { mode in
                    model.collageSetMode(mode)
                }
                .frame(width: 196)
                Spacer(minLength: 0)
                if state.loading { ProgressView().tint(.white) }
                Text("\(state.params.pictures.count) 张图")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.dim)
            }
            if let index = state.selected, state.params.pictures.indices.contains(index) {
                pictureActions(index)
            } else if state.params.mode == .template {
                templateSection
            } else {
                stitchSection
            }
            if let note = state.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .imageSource(isPresented: $model.collageState.pickerShown, limit: state.pickerLimit) { items in
            model.collageImport(items)
        }
    }

    // MARK: 模板

    private var templateSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Chip(title: "版式", selected: page == .layout) { page = .layout }
                Chip(title: "间距 · 圆角 · 底色", selected: page == .style) { page = .style }
                Spacer()
            }
            if page == .layout { layoutPage } else { stylePage }
        }
    }

    private var layoutPage: some View {
        let state = model.collageState
        return VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 6) {
                    ratioChip("全部", selected: state.ratioFilter == nil) { model.collageSetRatioFilter(nil) }
                    ForEach(CollageRatio.allCases) { ratio in
                        ratioChip(ratio.title, selected: state.ratioFilter == ratio) { model.collageSetRatioFilter(ratio) }
                    }
                }
            }
            if Platform.isMac {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 6)], spacing: 6) {
                        ForEach(model.collageChoices) { choice in
                            Button { model.collageSelect(choice.layout, ratio: choice.ratio) } label: {
                                CollageLayoutIcon(layout: choice.layout, ratio: choice.ratio.value,
                                                  selected: choice.layout == state.params.layout && choice.ratio == state.params.ratio)
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                        .padding(.vertical, 1)
                }
                .frame(height: 360)
            } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, spacing: 6) {
                    ForEach(model.collageChoices) { choice in
                        Button { model.collageSelect(choice.layout, ratio: choice.ratio) } label: {
                            CollageLayoutIcon(layout: choice.layout, ratio: choice.ratio.value,
                                              selected: choice.layout == state.params.layout && choice.ratio == state.params.ratio)
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel("\(choice.layout.cells.count) 格，\(choice.ratio.title)")
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(height: 112)
            .padding(.horizontal, -16)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            }
        }
    }

    private func ratioChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(selected ? Color.white : Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var stylePage: some View {
        let key = styleKey
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("\(Int((styleValue(key) / key.limit * 100).rounded()))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
                Slider(value: Binding(get: { Double(styleValue(key) / key.limit) },
                                      set: { setStyle(key, CGFloat($0) * key.limit) }), in: 0...1)
            }
            HStack(spacing: 4) {
                ForEach(StyleKey.allCases) { item in
                    IconTile(symbol: item.symbol, title: item.title, selected: item == key,
                             modified: styleValue(item) > 0) { styleKey = item }
                }
                Spacer()
            }
            colorRow
        }
    }

    private func styleValue(_ key: StyleKey) -> CGFloat {
        let params = model.collageState.params
        switch key {
        case .gap: return params.gap
        case .corner: return params.corner
        case .margin: return params.margin
        }
    }

    private func setStyle(_ key: StyleKey, _ value: CGFloat) {
        let v = value < key.limit * 0.02 ? 0 : value
        switch key {
        case .gap: model.collageState.params.gap = v
        case .corner: model.collageState.params.corner = v
        case .margin: model.collageState.params.margin = v
        }
        model.renderCollage()
    }

    /// 底色：间距、边距和拼接的间隔露出来的颜色。
    private var colorRow: some View {
        let current = model.collageState.params.background
        return HStack(spacing: 10) {
            Text("底色")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
            HScroll {
                HRow(spacing: 8) {
                    ForEach(CollageColor.palette.indices, id: \.self) { index in
                        let color = CollageColor.palette[index]
                        Button {
                            model.collageState.params.background = color
                            model.renderCollage()
                        } label: {
                            Circle()
                                .fill(Color(red: color.r, green: color.g, blue: color.b))
                                .frame(width: 24, height: 24)
                                .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().stroke(color == current ? Theme.accent : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
            ColorPicker("自选底色", selection: Binding(
                get: { Color(red: current.r, green: current.g, blue: current.b) },
                set: { picked in
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    UIColor(picked).getRed(&r, green: &g, blue: &b, alpha: &a)
                    model.collageState.params.background = CollageColor(r: min(max(r, 0), 1), g: min(max(g, 0), 1),
                                                                        b: min(max(b, 0), 1))
                    model.renderCollage()
                }), supportsOpacity: false)
                .labelsHidden()
        }
    }

    // MARK: 拼接

    private var stitchSection: some View {
        let params = model.collageState.params
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                directionButton("竖拼", symbol: "rectangle.split.1x2", selected: params.vertical) {
                    model.collageSetVertical(true)
                }
                directionButton("横拼", symbol: "rectangle.split.2x1", selected: !params.vertical) {
                    model.collageSetVertical(false)
                }
            }
            Button { model.collageRequestAdd() } label: {
                Label("添加图片", systemImage: "photo.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(PressStyle())
            HStack(spacing: 12) {
                Text("间隔")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 40, alignment: .leading)
                Slider(value: Binding(get: { Double(params.stitchGap / 0.08) },
                                      set: {
                                          let v = CGFloat($0) * 0.08
                                          model.collageState.params.stitchGap = v < 0.002 ? 0 : v
                                          model.renderCollage()
                                      }), in: 0...1)
            }
            if params.stitchGap > 0 {
                colorRow
            }
        }
    }

    private func directionButton(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Theme.accent : Color.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 选中了某一张图

    private func pictureActions(_ index: Int) -> some View {
        let params = model.collageState.params
        let template = params.mode == .template
        let last = index == params.pictures.count - 1
        let back = template ? "arrow.left" : (params.vertical ? "arrow.up" : "arrow.left")
        let forward = template ? "arrow.right" : (params.vertical ? "arrow.down" : "arrow.right")
        return VStack(spacing: 8) {
            HStack {
                Text(template ? "第 \(index + 1) 格" : "第 \(index + 1) 张")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                Button("完成") { model.collageState.selected = nil }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            HScroll {
                HRow(spacing: 4) {
                    IconTile(symbol: "arrow.triangle.2.circlepath", title: "换图") { model.collageRequestReplace(index) }
                    IconTile(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", title: "翻转") {
                        model.collageFlip(index)
                    }
                    IconTile(symbol: "rotate.right", title: "旋转") { model.collageRotate(index) }
                    IconTile(symbol: back, title: "前移") { model.collageMove(index, by: -1) }
                        .opacity(index == 0 ? 0.35 : 1)
                    IconTile(symbol: forward, title: "后移") { model.collageMove(index, by: 1) }
                        .opacity(last ? 0.35 : 1)
                    if template {
                        IconTile(symbol: "arrow.counterclockwise", title: "位置还原") { model.collageResetFit(index) }
                    }
                    IconTile(symbol: "trash", title: "删除") { model.collageRemove(index) }
                }
            }
        }
    }
}
