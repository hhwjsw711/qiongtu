import SwiftUI

/// Mac 版右边的"图层"面板，像专业修图软件那样常驻：可以折叠；随时选图层、新建、删除、复制、调顺序、
/// 改混合模式和不透明度、显示 / 隐藏。用到时自动打开图层工具，换到别的工具时自动应用。
struct MacLayersPanel: View {
    let model: EditorModel
    @AppStorage("mac.layersOpen") private var open = true
    @State private var picking = false
    @State private var featherDraft: CGFloat?

    private var live: Bool { model.tool == .layers }

    /// 图层工具开着时用正在改的；没开时显示历史里最后一次的图层。
    private var layers: [ImageLayer] {
        if live { return model.layerState.layers }
        for op in model.ops.reversed() {
            if case .layers(let stack) = op { return stack.layers }
        }
        return []
    }

    private var selectedID: UUID? { live ? model.layerState.selectedID : nil }
    private var selected: ImageLayer? { layers.first { $0.id == selectedID } }

    /// 文字、贴纸、形状：也是浮在照片上的一层。
    private var decorations: [OverlayItem] {
        model.ops.flatMap { op -> [OverlayItem] in
            if case .overlay(let items) = op { return items }
            return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if open {
                VStack(spacing: 0) {
                    controls
                    Rectangle().fill(MacTheme.line).frame(height: 1)
                    list
                    Rectangle().fill(MacTheme.line).frame(height: 1)
                    toolbar
                    if let note = model.layerState.note, live {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 6)
                    }
                }
                .disabled(model.isBusy || model.aiRunning || model.layerState.busy || model.isLoading)
                .transition(.opacity)
            }
        }
        .imageSource(isPresented: $picking) { items in
            guard let item = items.first else { return }
            Task {
                guard let data = await item() else {
                    model.layerState.note = "这张图片读不出来。"
                    return
                }
                ensureLayers { model.addLayer(data: data) }
            }
        }
    }

    // MARK: 标题

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(Theme.dim)
                Image(systemName: "square.3.layers.3d").font(.system(size: 11))
                Text("图层").font(.system(size: 12, weight: .bold))
                if model.layerState.fusing && live {
                    ProgressView().controlSize(.mini)
                    Text("正在融合…").font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                Spacer()
                Text("\(layers.count + decorations.count + 1)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(MacTheme.header)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(MacTheme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(MacTheme.line).frame(height: open ? 1 : 0) }
    }

    // MARK: 混合模式 + 不透明度

    private var controls: some View {
        let layer = selected
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(LayerBlend.allCases) { blend in
                        Button {
                            if let id = layer?.id { model.updateLayer(id) { $0.blend = blend } }
                        } label: {
                            if layer?.blend == blend { Label(blend.title, systemImage: "checkmark") } else { Text(blend.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(layer?.blend.title ?? "正常").font(.system(size: 12))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 112, height: 24)
                    .background(MacTheme.line, in: RoundedRectangle(cornerRadius: 5))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("混合模式")
                Text("不透明度").font(.system(size: 11)).foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { Double(layer?.opacity ?? 1) },
                                      set: { v in if let id = layer?.id { model.updateLayer(id) { $0.opacity = CGFloat(v) } } }),
                       in: 0...1)
                    .controlSize(.mini)
                Text("\(Int(((layer?.opacity ?? 1) * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
            if let layer, layer.cutout {
                HStack(spacing: 8) {
                    Text("边缘羽化").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Slider(value: Binding(get: { Double(featherDraft ?? layer.feather) },
                                          set: { featherDraft = CGFloat($0) }), in: 0...1) { editing in
                        // 羽化要重新抠一遍边，松手才算。
                        if !editing, let draft = featherDraft {
                            featherDraft = nil
                            model.setLayerFeather(layer.id, draft)
                        }
                    }
                    .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(layer == nil)
        .opacity(layer == nil ? 0.4 : 1)
    }

    // MARK: 图层列表（上面的排前面）

    private var list: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(decorations.reversed()) { item in
                    row(title: Self.decorationTitle(item), image: OverlayRenderer.thumbnail(item, fontSize: 30),
                        symbol: item.isGraphic ? "square.on.circle" : (item.isSticker ? "face.smiling" : "textformat"),
                        selected: false, hidden: nil, detail: nil) {
                        let tool: Tool = item.isGraphic ? .graphic : (item.isSticker ? .sticker : .text)
                        model.commitTool { model.open(tool, selecting: item.id) }
                    }
                }
                ForEach(layers.reversed()) { layer in
                    row(title: layer.name, image: UIImage(cgImage: layer.preview), symbol: nil,
                        selected: selectedID == layer.id, hidden: layer.hidden,
                        detail: layer.blend == .normal ? nil : layer.blend.title,
                        toggleHidden: { ensureLayers { model.updateLayer(layer.id) { $0.hidden.toggle() } } }) {
                        ensureLayers { model.layerState.selectedID = layer.id }
                    }
                }
                row(title: "照片", image: live ? model.layerState.backgroundThumb : model.displayImage, symbol: nil,
                    selected: live && selectedID == nil, hidden: nil, detail: nil) {
                    ensureLayers { model.layerState.selectedID = nil }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: layers.count + decorations.count < 4)
    }

    private func row(title: String, image: UIImage?, symbol: String?, selected: Bool, hidden: Bool?, detail: String?,
                     toggleHidden: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            // 小眼睛：图层才有；文字贴纸留空位对齐。
            Group {
                if let hidden, let toggleHidden {
                    Button(action: toggleHidden) {
                        Image(systemName: hidden ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(hidden ? Theme.dim : Color.white)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(hidden ? "显示" : "隐藏")
                } else {
                    Color.clear
                }
            }
            .frame(width: 22)
            Button(action: action) {
                HStack(spacing: 8) {
                    ZStack {
                        Color(white: 0.2)
                        if let image {
                            Image(uiImage: image).resizable().scaledToFit().padding(1)
                        } else if let symbol {
                            Image(systemName: symbol).font(.system(size: 12))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accent : MacTheme.line, lineWidth: selected ? 1.5 : 1))
                    .opacity(hidden == true ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                        if let detail {
                            Text(detail).font(.system(size: 10)).foregroundStyle(Theme.dim)
                        }
                    }
                    Spacer(minLength: 0)
                    if let symbol, image != nil {
                        Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.dim)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(selected ? Theme.accent.opacity(0.18) : Color.clear)
    }

    // MARK: 底下一排按钮

    private var toolbar: some View {
        let layer = selected
        let index = layer.flatMap { l in layers.firstIndex { $0.id == l.id } } ?? 0
        return HStack(spacing: 2) {
            MacIconButton(symbol: "plus.square", help: "新建图层（打开图片）") { picking = true }
            MacIconButton(symbol: "square.on.square", help: "复制图层") {
                if let id = layer?.id { model.duplicateLayer(id) }
            }
            .disabled(layer == nil)
            MacIconButton(symbol: "arrow.up", help: "上移一层") {
                if let id = layer?.id { model.moveLayer(id, by: 1) }
            }
            .disabled(layer == nil || index >= layers.count - 1)
            MacIconButton(symbol: "arrow.down", help: "下移一层") {
                if let id = layer?.id { model.moveLayer(id, by: -1) }
            }
            .disabled(layer == nil || index <= 0)
            MacIconButton(symbol: "person.crop.rectangle", help: "去背景") {
                if let l = layer { model.setLayerCutout(l.id, !l.cutout) }
            }
            .disabled(layer == nil)
            Spacer()
            MacIconButton(symbol: "wand.and.sparkles", help: "AI 融合") { ensureLayers { model.fuseLayers() } }
                .disabled(layers.isEmpty)
            MacIconButton(symbol: "trash", help: "删除图层") {
                if let id = layer?.id { model.removeLayer(id) }
            }
            .disabled(layer == nil)
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    // MARK: 打开图层工具

    /// 图层工具没开就先打开（开着别的工具就先应用掉），再做 action。
    private func ensureLayers(_ action: @escaping () -> Void) {
        if model.tool == .layers {
            action()
        } else if model.tool != nil {
            model.commitTool { model.open(.layers) { action() } }
        } else {
            model.open(.layers) { action() }
        }
    }

    private static func decorationTitle(_ item: OverlayItem) -> String {
        if let g = item.graphic { return g.kind.title }
        if item.isImage { return "贴纸" }
        if item.isSticker { return item.text }
        return String(item.text.replacingOccurrences(of: "\n", with: " ").prefix(8))
    }
}
