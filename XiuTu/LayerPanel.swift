import PhotosUI
import SwiftUI

/// 图层工具的画布：显示合成后的样子；点一下选中图层，拖动移动，双指或右下角手柄缩放旋转。
struct LayerCanvas: View {
    @Bindable var model: EditorModel

    private static let space = "layerCanvas"

    var body: some View {
        GeometryReader { geo in
            let box = CGSize(width: geo.size.width - 32, height: geo.size.height - 32)
            let fitted = aspectFit(model.displayImage?.size ?? CGSize(width: 1, height: 1), in: box)
            ZStack {
                ZStack {
                    if let image = model.displayImage {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .onTapGesture { model.layerState.selectedID = nil }
                    }
                    ForEach(model.layerState.layers) { layer in
                        if !layer.hidden {
                            LayerHitView(model: model, layer: layer, fitted: fitted, space: Self.space)
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .clipped()

                if let layer = model.selectedLayer, !layer.hidden {
                    LayerChrome(model: model, layer: layer, fitted: fitted, space: Self.space)
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .coordinateSpace(name: Self.space)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

/// 图层在画布上占的那一块（看不见），负责接手势。
private struct LayerHitView: View {
    let model: EditorModel
    let layer: ImageLayer
    let fitted: CGSize
    let space: String

    @State private var dragStart: CGPoint?
    @State private var pinchStart: CGFloat?
    @State private var rotateStart: CGFloat?

    var body: some View {
        let w = layer.width * fitted.width
        Color.clear
            .frame(width: max(w, 24), height: max(w * layer.aspect, 24))
            .contentShape(Rectangle())
            .rotationEffect(.radians(layer.rotation))
            .onTapGesture { model.layerState.selectedID = layer.id }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = layer.center
                            model.layerState.selectedID = layer.id
                        }
                        guard let s = dragStart, fitted.width > 0, fitted.height > 0 else { return }
                        let x = s.x + value.translation.width / fitted.width
                        let y = s.y + value.translation.height / fitted.height
                        model.updateLayer(layer.id) {
                            $0.center = CGPoint(x: min(max(x, -0.3), 1.3), y: min(max(y, -0.3), 1.3))
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil {
                            pinchStart = layer.width
                            model.layerState.selectedID = layer.id
                        }
                        guard let s = pinchStart else { return }
                        model.updateLayer(layer.id) { $0.width = min(max(s * value.magnification, 0.03), 6) }
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { value in
                        if rotateStart == nil { rotateStart = layer.rotation }
                        guard let s = rotateStart else { return }
                        model.updateLayer(layer.id) { $0.rotation = s + CGFloat(value.rotation.radians) }
                    }
                    .onEnded { _ in rotateStart = nil }
            )
            .position(x: layer.center.x * fitted.width, y: layer.center.y * fitted.height)
    }
}

/// 选中图层的虚线框，加上删除和缩放旋转两个手柄。
private struct LayerChrome: View {
    let model: EditorModel
    let layer: ImageLayer
    let fitted: CGSize
    let space: String

    private struct HandleStart {
        let length: CGFloat
        let angle: CGFloat
        let width: CGFloat
        let rotation: CGFloat
    }

    @State private var start: HandleStart?

    var body: some View {
        let w = max(layer.width * fitted.width, 24)
        let size = CGSize(width: w, height: max(w * layer.aspect, 24))
        let center = CGPoint(x: layer.center.x * fitted.width, y: layer.center.y * fitted.height)
        ZStack {
            Rectangle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .allowsHitTesting(false)
            handle("xmark")
                .onTapGesture { model.removeLayer(layer.id) }
                .offset(x: -size.width / 2, y: -size.height / 2)
            handle("arrow.up.left.and.arrow.down.right")
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                        .onChanged { value in
                            if start == nil {
                                let v = CGPoint(x: value.startLocation.x - center.x, y: value.startLocation.y - center.y)
                                start = HandleStart(length: max(hypot(v.x, v.y), 1), angle: atan2(v.y, v.x),
                                                    width: layer.width, rotation: layer.rotation)
                            }
                            guard let s = start else { return }
                            let v = CGPoint(x: value.location.x - center.x, y: value.location.y - center.y)
                            let length = max(hypot(v.x, v.y), 1)
                            let angle = atan2(v.y, v.x)
                            model.updateLayer(layer.id) {
                                $0.width = min(max(s.width * length / s.length, 0.03), 6)
                                $0.rotation = s.rotation + angle - s.angle
                            }
                        }
                        .onEnded { _ in start = nil }
                )
                .offset(x: size.width / 2, y: size.height / 2)
        }
        .frame(width: size.width, height: size.height)
        .rotationEffect(.radians(layer.rotation))
        .position(center)
    }

    private func handle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 26, height: 26)
            .background(Color.white, in: Circle())
            .contentShape(Circle().inset(by: -8))
    }
}

/// 图层面板：上面一排是所有图层（最上面的排最前），下面是选中那一层能做的事。
struct LayerPanel: View {
    @Bindable var model: EditorModel

    @State private var pickingLayer = false
    @State private var editRequest: LayerEditRequest?
    /// 滑块当前调的是不是羽化（否则是不透明度）。
    @State private var adjustingFeather = false
    @State private var featherDraft: CGFloat?

    var body: some View {
        VStack(spacing: 10) {
            if model.layerState.fusing {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("正在融合… \(max(0, Int(context.date.timeIntervalSince(model.layerState.fuseStarted)))) 秒")
                            .font(.system(size: 14))
                            .monospacedDigit()
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            strip
            if let layer = model.selectedLayer {
                sliderRow(layer)
                actions(layer)
            } else {
                backgroundRow
            }
            if let note = model.layerState.note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .imageSource(isPresented: $pickingLayer) { items in
            guard let item = items.first else { return }
            Task {
                if let data = await item() {
                    model.addLayer(data: data)
                } else {
                    model.layerState.note = "这张图片读不出来。"
                }
            }
        }
        .fullScreenCover(item: $editRequest) { request in
            EditorView(assetID: "", layerEdit: request, initialTool: nil) { editRequest = nil }
        }
    }

    // MARK: 图层列表

    private var strip: some View {
        HScroll {
            HRow(alignment: .top, spacing: 10) {
                Button { pickingLayer = true } label: {
                    VStack(spacing: 6) {
                        Group {
                            if model.layerState.busy {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                            }
                        }
                        .foregroundStyle(.black)
                        .frame(width: 54, height: 54)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text("添加")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.layerState.busy)
                if !model.layerState.layers.isEmpty {
                    Button { model.fuseLayers() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "wand.and.sparkles")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 54, height: 54)
                                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: 5, y: -4) }
                            Text("AI 融合").font(.system(size: 11.5)).foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(PressStyle())
                    .disabled(model.layerState.busy)
                }
                // 文字、贴纸、形状也是浮在照片上的一层：点一下转到对应的工具接着改。
                ForEach(decorations.reversed()) { item in
                    thumb(title: Self.decorationTitle(item), image: OverlayRenderer.thumbnail(item, fontSize: 30),
                          selected: false, hidden: false) {
                        let tool: Tool = item.isGraphic ? .graphic : (item.isSticker ? .sticker : .text)
                        model.commitTool { model.open(tool, selecting: item.id) }
                    }
                }
                ForEach(model.layerState.layers.reversed()) { layer in
                    thumb(title: layer.name, image: UIImage(cgImage: layer.preview),
                          selected: model.layerState.selectedID == layer.id, hidden: layer.hidden) {
                        model.layerState.selectedID = layer.id
                    }
                }
                thumb(title: "照片", image: model.layerState.backgroundThumb,
                      selected: model.layerState.selectedID == nil, hidden: false) {
                    model.layerState.selectedID = nil
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6).padding(.bottom, 2)
        }
        .padding(.horizontal, -16)
    }

    /// 历史里所有的文字、贴纸、形状（先加的在前）。
    private var decorations: [OverlayItem] {
        model.ops.flatMap { op -> [OverlayItem] in
            if case .overlay(let items) = op { return items }
            return []
        }
    }

    private static func decorationTitle(_ item: OverlayItem) -> String {
        if let g = item.graphic { return g.kind.title }
        if item.isImage { return "贴纸" }
        if item.isSticker { return item.text }
        return String(item.text.replacingOccurrences(of: "\n", with: " ").prefix(5))
    }

    private func thumb(title: String, image: UIImage?, selected: Bool, hidden: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Color(white: 0.2)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().padding(2)
                    }
                    if hidden {
                        Color.black.opacity(0.55)
                        Image(systemName: "eye.slash").font(.system(size: 16)).foregroundStyle(.white)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5)
                )
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .frame(width: 58)
            }
        }
        .buttonStyle(PressStyle())
    }

    // MARK: 选中图层

    private func sliderRow(_ layer: ImageLayer) -> some View {
        let feather = adjustingFeather && layer.cutout
        let value = feather ? (featherDraft ?? layer.feather) : layer.opacity
        return HStack(spacing: 12) {
            Button {
                if layer.cutout { adjustingFeather.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(feather ? "边缘羽化" : "不透明度")
                    if layer.cutout {
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(layer.cutout ? Color.white : Theme.dim)
                .frame(width: 78, alignment: .leading)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(
                get: { Double(value) },
                set: { new in
                    if feather {
                        featherDraft = CGFloat(new)
                    } else {
                        model.updateLayer(layer.id) { $0.opacity = CGFloat(new) }
                    }
                }
            ), in: 0...1) { editing in
                // 羽化要重新抠一遍边，松手才算。
                if !editing, feather, let draft = featherDraft {
                    featherDraft = nil
                    model.setLayerFeather(layer.id, draft)
                }
            }
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func actions(_ layer: ImageLayer) -> some View {
        let id = layer.id
        let busy = model.layerState.busy
        let index = model.layerState.layers.firstIndex { $0.id == id } ?? 0
        return HScroll {
            HRow(spacing: 2) {
                IconTile(symbol: "slider.horizontal.3", title: "编辑", modified: !layer.ops.isEmpty) {
                    editRequest = model.layerEditRequest(for: id)
                }
                IconTile(symbol: busy ? "hourglass" : "person.crop.rectangle", title: "去背景", selected: layer.cutout) {
                    model.setLayerCutout(id, !layer.cutout)
                }
                IconTile(symbol: "wand.and.stars", title: "AI 去背景", badge: "AI") {
                    model.aiCutoutLayer(id)
                }
                Menu {
                    ForEach(LayerBlend.allCases) { blend in
                        Button {
                            model.updateLayer(id) { $0.blend = blend }
                        } label: {
                            if layer.blend == blend {
                                Label(blend.title, systemImage: "checkmark")
                            } else {
                                Text(blend.title)
                            }
                        }
                    }
                } label: {
                    tileLabel(symbol: "circle.lefthalf.filled",
                              title: layer.blend == .normal ? "混合" : layer.blend.title,
                              selected: layer.blend != .normal)
                }
                IconTile(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", title: "翻转",
                         selected: layer.flipped) {
                    model.updateLayer(id) { $0.flipped.toggle() }
                }
                IconTile(symbol: "arrow.up.left.and.arrow.down.right", title: "铺满") { model.fitLayer(id) }
                IconTile(symbol: "square.on.square", title: "复制") { model.duplicateLayer(id) }
                IconTile(symbol: "arrow.up.square", title: "上移") { model.moveLayer(id, by: 1) }
                    .opacity(index < model.layerState.layers.count - 1 ? 1 : 0.35)
                IconTile(symbol: "arrow.down.square", title: "下移") { model.moveLayer(id, by: -1) }
                    .opacity(index > 0 ? 1 : 0.35)
                IconTile(symbol: layer.hidden ? "eye" : "eye.slash", title: layer.hidden ? "显示" : "隐藏") {
                    model.updateLayer(id) { $0.hidden.toggle() }
                }
                IconTile(symbol: "trash", title: "删除") { model.removeLayer(id) }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
    }

    // MARK: 选中下面的照片

    private var backgroundRow: some View {
        HStack(spacing: 2) {
            IconTile(symbol: "slider.horizontal.3", title: "编辑照片") {
                editRequest = model.backgroundEditRequest()
            }
            Spacer()
        }
        .disabled(model.layerState.busy)
    }

    /// 和 IconTile 长得一样，但不是按钮（给 Menu 当标签用）。
    private func tileLabel(symbol: String, title: String, selected: Bool) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .frame(width: 44, height: 30)
            Text(title).font(.system(size: 12)).lineLimit(1)
        }
        .foregroundStyle(selected ? Theme.accent : Color.white)
        .frame(minWidth: 58)
    }
}
