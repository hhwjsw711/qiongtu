import SwiftUI

/// 底部一级菜单。
enum MainTab: String, CaseIterable, Identifiable {
    case tools, beauty, body, hair, filter, effect, adjust, deco, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return "工具"
        case .beauty: return "美颜"
        case .body: return "美体"
        case .hair: return "美发"
        case .filter: return "滤镜"
        case .effect: return "特效"
        case .adjust: return "调色"
        case .deco: return "装饰"
        case .ai: return "AI 修图"
        }
    }

    /// 点一下直接进入的工具；nil = 切换上方的二级菜单。
    var directTool: Tool? {
        switch self {
        case .filter: return .filter
        case .effect: return .effect
        case .adjust: return .adjust
        default: return nil
        }
    }

    /// 这个一级菜单下面的二级入口。
    var entries: [MenuEntry] {
        switch self {
        case .tools:
            return [
                MenuEntry(tool: .crop), MenuEntry(tool: .filter), MenuEntry(tool: .adjust),
                MenuEntry(title: "消除", symbol: "eraser", badge: "AI", action: .erase),
                MenuEntry(tool: .collage), MenuEntry(tool: .layers),
            ]
        case .beauty:
            return [
                MenuEntry(title: "满意脸型", symbol: "star.fill", badge: "AI", action: .favoriteFace),
                MenuEntry(title: "一键美颜", symbol: "sparkles", badge: "AI", action: .beauty(manual: false)),
                MenuEntry(tool: .reshape), MenuEntry(tool: .makeup), MenuEntry(tool: .skin),
                MenuEntry(title: "手动美颜", symbol: "slider.horizontal.3", action: .beauty(manual: true)),
            ]
        case .body:
            return [
                MenuEntry(title: "一键美体", symbol: "figure.stand", action: .shape(.preset)),
                MenuEntry(title: "塑形", symbol: "figure.arms.open", action: .shape(.shape)),
                MenuEntry(title: "增高", symbol: "arrow.up.and.down", action: .shape(.tall)),
                MenuEntry(title: "瘦身", symbol: "arrow.right.and.line.vertical.and.arrow.left", action: .shape(.slim)),
                MenuEntry(title: "缩放", symbol: "circle.dashed", action: .shape(.zoom)),
                MenuEntry(title: "推拉", symbol: "hand.draw", action: .tool(.liquify)),
                MenuEntry(title: "AI 美体", symbol: "sparkles", badge: "AI", action: .ai(.body)),
            ]
        case .hair:
            return AIPresetGroup.hairGroups.map {
                MenuEntry(title: $0.title, symbol: $0.symbol, badge: "AI", action: .ai($0))
            }
        case .deco:
            return [
                MenuEntry(tool: .sticker), MenuEntry(tool: .text), MenuEntry(tool: .graphic), MenuEntry(tool: .doodle), MenuEntry(tool: .frame),
                MenuEntry(tool: .backdrop), MenuEntry(tool: .mark), MenuEntry(tool: .mosaic),
            ]
        case .ai:
            return AIPresetGroup.editGroups.map {
                MenuEntry(title: $0.menuTitle, symbol: $0.symbol, badge: "AI", action: .ai($0))
            }
        case .filter, .effect, .adjust:
            return []
        }
    }
}

/// 二级菜单里点了之后做什么。
enum MenuAction {
    case tool(Tool)
    /// 打开 AI 修图里的某一组。
    case ai(AIPresetGroup)
    /// AI 消除：直接进涂抹。
    case erase
    case beauty(manual: Bool)
    /// 进美颜后直接按满意脸型修。
    case favoriteFace
    /// 美体塑形，直接进到指定的那一种做法。
    case shape(ShapeMode)
}

/// 二级菜单里的一个入口。
struct MenuEntry: Identifiable {
    let title: String
    let symbol: String
    var badge: String? = nil
    let action: MenuAction

    var id: String { title }

    init(title: String, symbol: String, badge: String? = nil, action: MenuAction) {
        self.title = title
        self.symbol = symbol
        self.badge = badge
        self.action = action
    }

    init(tool: Tool) {
        self.init(title: tool.title, symbol: tool.symbol, action: .tool(tool))
    }
}

struct EditorView: View {
    let assetID: String
    /// 不为空时从这个文件打开，而不是从相册。
    var fileURL: URL? = nil
    /// 不为空时编辑的是一个图层自己的内容（或者图层下面的照片）：从给的图和步骤开始，点"完成"把步骤交回去。
    var layerEdit: LayerEditRequest? = nil
    /// 从草稿箱接着编辑上次没做完的图。
    var restoreDraft = false
    /// 打开后把历史图库里这张图的处理步骤套到这张照片上。
    var recipeID: UUID? = nil
    /// 自动拼图：打开拼接页并摆好这组截图。
    var stitchJob: AutoStitchJob? = nil
    let initialTool: Tool?
    var onClose: () -> Void

    @State private var model = EditorModel()
    private var embedded: Bool { layerEdit != nil }
    private var isSaved: Bool { savedRevision == model.revision }
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var toast: String?
    @State private var toastID = 0
    @State private var editingTextID: UUID?
    @State private var editingPrompt = false
    @State private var showSettings = false
    @State private var showSave = false
    /// 上次保存成功时的编辑状态；和现在一样就说明保存之后没再改过。
    @State private var savedRevision: Int?
    /// 底部一级菜单停在哪一项：进出工具时记住，不跳回"工具"。
    @State private var mainTab: MainTab = .tools

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.frame(height: 52)
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .top) {
                        // 单独编辑图层内容时，标出改的是哪一层。
                        if let layerEdit {
                            Text("正在编辑：\(layerEdit.title)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Theme.accent, in: Capsule())
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                        }
                        if let status = model.recipeStatus {
                            HStack(spacing: 10) {
                                ProgressView().tint(.black).controlSize(.small)
                                Text(status)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                Button("停止") { model.stopRecipe() }
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accent, in: Capsule())
                            .padding(.top, 6)
                            .padding(.horizontal, 16)
                        }
                    }
                bottom
                    .disabled(model.recipeStatus != nil)
            }
            .ignoresSafeArea(.keyboard)
            if model.isLoading || model.isBusy || saving {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(24)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
            if let error = model.errorText {
                Text(error).foregroundStyle(Theme.dim)
            }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Color(white: 0.2).opacity(0.95), in: Capsule())
                        .padding(.bottom, 230)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            if let id = editingTextID {
                TextInputOverlay(initial: model.overlayItems.first { $0.id == id }?.text ?? "", placeholder: "输入文字") { text in
                    finishTextEditing(id: id, text: text)
                }
            }
            if editingPrompt {
                TextInputOverlay(initial: model.aiPrompt, placeholder: "写下要怎么改，比如：把背景换成海边") { text in
                    model.aiPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    editingPrompt = false
                    // 写完直接开始；什么都没写，或者只留着"换成："这样的半句话，就不发。
                    if !model.aiPrompt.isEmpty, !model.aiPrompt.hasSuffix("：") { model.runAI() }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            model.draftEnabled = !embedded
            if let layerEdit {
                await model.load(image: layerEdit.source, ops: layerEdit.ops)
            } else if restoreDraft {
                await model.loadDraft()
            } else if let fileURL {
                await model.load(fileURL: fileURL)
            } else {
                await model.load(assetID: assetID)
            }
            if let initialTool { start(initialTool) }
            if let stitchJob { model.collageLoadAutoStitch(stitchJob) }
            if let recipeID, let recipe = HistoryStore.shared.recipe(recipeID) { model.startRecipe(recipe) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSave) { SaveSheet(model: model, onSave: save) }
        .confirmationDialog("放弃当前修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { leave() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 4) {
            if model.tool == nil {
                Button {
                    // 保存之后没再改过，就直接返回，不用再问。
                    if (embedded ? model.hasChanges : model.hasEdits), !isSaved { confirmDiscard = true } else { leave() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }
                .disabled(!model.canUndo)
                .opacity(model.canUndo ? 1 : 0.3)
                Button { model.redo() } label: {
                    Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44)
                }
                .disabled(!model.canRedo)
                .opacity(model.canRedo ? 1 : 0.3)
                Spacer()
                if let layerEdit {
                    // 单独编辑图层内容：不存相册，把修改步骤交回图层。
                    Button {
                        layerEdit.onDone(model.ops)
                        onClose()
                    } label: {
                        Text("完成")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accent, in: Capsule())
                    }
                    .disabled(model.isLoading || model.isBusy)
                } else {
                    if isSaved {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.green)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.trailing, 4)
                    }
                    Button { showSave = true } label: {
                        Text("保存")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                    }
                    .disabled(model.isLoading || saving)
                }
            }
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    // MARK: 画布

    @ViewBuilder
    private var canvas: some View {
        switch model.tool {
        case .some(.crop):
            CropCanvas(model: model)
        case .some(.text), .some(.sticker), .some(.graphic):
            OverlayCanvas(model: model) { id in editingTextID = id }
        case .some(.beauty):
            ZoomableCanvas(image: model.shownImage, handlers: nil, focus: model.focusRect,
                           detail: model.comparing ? nil : model.detailImage, detailRect: model.detailRect,
                           onViewport: { rect, pixels in model.setViewport(rect, pixels: pixels) },
                           onTap: { point in model.tapFace(at: point) })
                .overlay(alignment: .bottomTrailing) { compareButton }
        case .some(.reshape):
            ZoomableCanvas(image: model.shownImage, handlers: model.reshapeState.wantsStrokes ? DrawHandlers(
                began: { point, scale in model.reshapeStrokeBegan(at: point, displayScale: scale) },
                moved: { point in model.reshapeStrokeMoved(to: point) },
                ended: { model.reshapeStrokeEnded() },
                cancelled: { model.reshapeStrokeCancelled() }
            ) : nil, focus: model.focusRect,
               detail: model.comparing ? nil : model.detailImage, detailRect: model.detailRect,
               onViewport: { rect, pixels in model.setViewport(rect, pixels: pixels) },
               onTap: { point in model.reshapeTapped(at: point) })
            .overlay(alignment: .bottomTrailing) { compareButton }
        case .some(.makeup):
            ZoomableCanvas(image: model.shownImage, handlers: model.makeupState.wantsStrokes ? DrawHandlers(
                began: { point, scale in model.makeupStrokeBegan(at: point, displayScale: scale) },
                moved: { point in model.makeupStrokeMoved(to: point) },
                ended: { model.makeupStrokeEnded() },
                cancelled: { model.makeupStrokeCancelled() }
            ) : nil, focus: model.focusRect,
               detail: model.comparing ? nil : model.detailImage, detailRect: model.detailRect,
               onViewport: { rect, pixels in model.setViewport(rect, pixels: pixels) },
               onTap: { point in model.makeupTapped(at: point) })
            .overlay(alignment: .bottomTrailing) { compareButton }
        case .some(.skin):
            ZoomableCanvas(image: model.shownImage, handlers: model.skinState.wantsStrokes ? DrawHandlers(
                began: { point, scale in model.skinStrokeBegan(at: point, displayScale: scale) },
                moved: { point in model.skinStrokeMoved(to: point) },
                ended: { model.skinStrokeEnded() },
                cancelled: { model.skinStrokeCancelled() }
            ) : nil, focus: model.focusRect,
               detail: model.comparing ? nil : model.detailImage, detailRect: model.detailRect,
               onViewport: { rect, pixels in model.setViewport(rect, pixels: pixels) },
               onTap: { point in model.skinTapped(at: point) })
            .overlay(alignment: .bottomTrailing) { compareButton }
        case .some(.shape):
            ShapeCanvas(model: model)
        case .some(.collage):
            CollageCanvas(model: model)
        case .some(.layers):
            LayerCanvas(model: model)
        case .some(.adjust):
            ZoomableCanvas(image: model.shownImage, handlers: nil,
                           detail: model.comparing ? nil : model.detailImage, detailRect: model.detailRect,
                           onViewport: { rect, pixels in model.setViewport(rect, pixels: pixels) },
                           onTap: { point in model.adjustTapped(at: point) })
                .overlay(alignment: .bottomTrailing) { compareButton }
        case .some(.mosaic), .some(.ai), .some(.liquify), .some(.doodle), .some(.mark):
            ZoomableCanvas(image: model.shownImage, handlers: DrawHandlers(
                began: { point, scale in model.strokeBegan(at: point, displayScale: scale) },
                moved: { point in model.strokeMoved(to: point) },
                ended: { model.strokeEnded() },
                cancelled: { model.strokeCancelled() }
            ), detail: model.comparing ? nil : model.detailImage, detailRect: model.detailRect,
               onViewport: { rect, pixels in model.setViewport(rect, pixels: pixels) })
            .overlay(alignment: .bottomTrailing) { compareButton }
        default:
            ZoomableCanvas(image: model.shownImage, handlers: nil,
                           detail: model.comparing ? nil : model.detailImage, detailRect: model.detailRect,
                           onViewport: { rect, pixels in model.setViewport(rect, pixels: pixels) },
                           onTap: { point in model.tapDecoration(at: point) })
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 0) {
                        if model.tool == nil, !embedded { layersButton }
                        compareButton
                    }
                }
        }
    }

    /// 图层：在照片上面再叠别的图。
    private var layersButton: some View {
        Button { start(.layers) } label: {
            Image(systemName: Tool.layers.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.bottom, -4)
        .opacity(model.isLoading ? 0 : 1)
    }

    /// 按住看修改前的样子。
    private var compareButton: some View {
        Image(systemName: "square.split.2x1")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color.black.opacity(0.55), in: Circle())
            .padding(12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.comparing { model.comparing = true } }
                    .onEnded { _ in model.comparing = false }
            )
            .opacity(model.isLoading ? 0 : 1)
    }

    // MARK: 底部

    @ViewBuilder
    private var bottom: some View {
        if let tool = model.tool {
            VStack(spacing: 0) {
                panel(for: tool)
                HStack {
                    Button { model.cancelTool() } label: {
                        Image(systemName: "xmark").frame(width: 52, height: 48)
                    }
                    Group {
                        switch tool {
                        case .adjust: AdjustTitle(model: model)
                        case .reshape: ReshapeTitle(model: model)
                        case .makeup: MakeupTitle(model: model)
                        case .skin: SkinTitle(model: model)
                        case .shape: ShapeTitle(model: model)
                        default: Text(title(for: tool)).font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    Button { model.commitTool() } label: {
                        Image(systemName: "checkmark").frame(width: 52, height: 48)
                    }
                }
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
            }
            .background(Theme.panel)
        } else {
            MainMenu(tab: $mainTab, embedded: embedded, onEntry: handle)
        }
    }

    @ViewBuilder
    private func panel(for tool: Tool) -> some View {
        switch tool {
        case .crop: CropPanel(model: model)
        case .filter: FilterPanel(model: model)
        case .adjust: AdjustPanel(model: model)
        case .mosaic: MosaicPanel(model: model)
        case .text: TextPanel(model: model, onAdd: addText)
        case .sticker: StickerPanel(model: model)
        case .graphic: GraphicPanel(model: model)
        case .ai: AIPanel(model: model, editPrompt: { editingPrompt = true }, openSettings: { showSettings = true })
        case .beauty: BeautyPanel(model: model, openSettings: { showSettings = true })
        case .liquify: LiquifyPanel(model: model)
        case .doodle: DoodlePanel(model: model)
        case .mark: MarkPanel(model: model)
        case .frame: FramePanel(model: model)
        case .backdrop: BackdropPanel(model: model)
        case .collage: CollagePanel(model: model)
        case .layers: LayerPanel(model: model)
        case .reshape: ReshapePanel(model: model)
        case .makeup: MakeupPanel(model: model)
        case .skin: SkinPanel(model: model)
        case .shape: ShapePanel(model: model)
        case .effect: EffectPanel(model: model)
        }
    }

    /// 底部确认栏中间的名字。AI 美体和手动美体都算"美体"。
    private func title(for tool: Tool) -> String {
        if tool == .ai, model.aiGroup == .body { return "美体" }
        if tool == .ai, model.aiGroup.isHair { return "美发" }
        return tool.title
    }

    // MARK: 动作

    /// 正常离开编辑器：草稿用不着了。
    private func leave() {
        model.discardDraft()
        onClose()
    }

    private func start(_ tool: Tool) {
        model.open(tool) {
            // 已经有文字时是回来改它们，不自动弹出新文字的输入框。
            if tool == .text, model.tool == .text, model.overlayItems.isEmpty { addText() }
        }
    }

    private func handle(_ action: MenuAction) {
        switch action {
        case .tool(let tool):
            start(tool)
        case .ai(let group):
            model.beginAI(group: group)
        case .erase:
            model.beginAI(group: .remove, prompt: AIPresetGroup.remove.presets[0].prompt)
        case .beauty(let manual):
            start(.beauty)
            if model.tool == .beauty { model.beautyMode = manual ? .manual : .ai }
        case .favoriteFace:
            guard FavoriteFaceStore.shared.current != nil else {
                show("还没有满意脸型")
                return
            }
            start(.beauty)
            if model.tool == .beauty {
                model.beautyMode = .ai
                model.runFavoriteAfterDetect = true
            }
        case .shape(let mode):
            start(.shape)
            if model.tool == .shape { model.setShapeMode(mode) }
        }
    }

    private func addText() {
        editingTextID = model.addOverlay(text: "", sticker: false)
    }

    private func finishTextEditing(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            model.removeOverlay(id)
        } else {
            model.updateOverlay(id) { $0.text = trimmed }
        }
        editingTextID = nil
    }

    private func save(_ options: SaveOptions) {
        saving = true
        let revision = model.revision
        Task {
            let ok = await model.export(options)
            saving = false
            if ok { savedRevision = revision }
            show(ok ? "已保存到相册" : "保存失败，请检查相册权限")
        }
    }

    private func show(_ message: String) {
        toastID += 1
        let id = toastID
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if id == toastID {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}

/// 没有打开任何工具时的底部：上面是当前一级菜单的二级入口，下面是一级菜单。
struct MainMenu: View {
    @Binding var tab: MainTab
    /// 单独编辑图层内容时不再提供"图层"入口。
    var embedded = false
    var onEntry: (MenuAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tab.entries.filter { !(embedded && $0.id == Tool.layers.title) }) { entry in
                        IconTile(symbol: entry.symbol, title: entry.title, badge: entry.badge) {
                            onEntry(entry.action)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 92)
            .id(tab)
            HStack(spacing: 0) {
                ForEach(MainTab.allCases) { item in
                    Button {
                        if let tool = item.directTool {
                            onEntry(.tool(tool))
                        } else {
                            tab = item
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 15, weight: item == tab ? .bold : .regular))
                                .foregroundStyle(item == tab ? Theme.accent : Color.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Capsule()
                                .fill(item == tab ? Theme.accent : Color.clear)
                                .frame(width: 18, height: 3)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 50)
        }
        .background(Theme.panel)
    }
}

/// 输入文字的浮层。
struct TextInputOverlay: View {
    let initial: String
    var placeholder = "输入文字"
    var onDone: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture { onDone(text) }
            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    Button("完成") { onDone(text) }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .lineLimit(1...5)
                    .focused($focused)
                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            text = initial
            focused = true
        }
    }
}
