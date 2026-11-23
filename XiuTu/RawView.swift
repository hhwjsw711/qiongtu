import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 选 RAW 文件：相册里的 RAW，或者从"文件"App 导入。
struct RawPickerView: View {
    var onEdit: (URL) -> Void
    var onClose: () -> Void

    struct Session: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }

    @State private var assets: [PHAsset] = []
    @State private var access: PhotoLibrary.Access = .unknown
    @State private var importing = false
    @State private var loading = false
    @State private var note: String?
    @State private var session: Session?

    private let spacing: CGFloat = 2
    private let columnCount = 4

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                content
            }
            if loading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(24)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task { await loadLibrary() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.rawImage, .image]) { result in
            guard case .success(let url) = result else { return }
            open(file: url)
        }
        .fullScreenCover(item: $session) { item in
            RawView(name: item.name, data: item.data, onClose: { session = nil }) { url in
                session = nil
                onEdit(url)
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("RAW 冲洗").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Button { importing = true } label: {
                    Label("从文件导入", systemImage: "folder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
    }

    @ViewBuilder
    private var content: some View {
        if let note {
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        if assets.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.dim)
                Text(access == .denied ? "没有相册权限，可以用右上角\u{201C}从文件导入\u{201D}。"
                                       : "相册里没有找到 RAW 照片。\n相机存储卡或网盘里的 RAW，用右上角\u{201C}从文件导入\u{201D}。")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        } else {
            GeometryReader { geo in
                let side = (geo.size.width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columnCount),
                              spacing: spacing) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            AssetThumb(asset: asset, side: side)
                                .overlay(alignment: .bottomLeading) {
                                    Text("RAW")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.9), in: Capsule())
                                        .padding(4)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { open(asset: asset) }
                        }
                    }
                }
            }
        }
    }

    private func loadLibrary() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            access = .denied
            return
        }
        access = .granted
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var list: [PHAsset] = []
        // 系统的"RAW"智能相簿：里面是所有带 RAW 原片的照片。
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumRAW, options: nil)
        albums.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in list.append(asset) }
        }
        assets = list
    }

    private func open(asset: PHAsset) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let raw = resources.first(where: { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }) else {
            note = "这张照片没有找到 RAW 原片。"
            return
        }
        note = nil
        loading = true
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        var buffer = Data()
        PHAssetResourceManager.default().requestData(for: raw, options: options, dataReceivedHandler: { chunk in
            buffer.append(chunk)
        }, completionHandler: { error in
            let data = buffer
            Task { @MainActor in
                loading = false
                if error != nil || data.isEmpty {
                    note = "读取 RAW 原片失败。如果照片存在 iCloud 里，请确认网络正常。"
                } else {
                    session = Session(name: raw.originalFilename, data: data)
                }
            }
        })
    }

    private func open(file url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            note = "读不了这个文件。"
            return
        }
        note = nil
        session = Session(name: url.lastPathComponent, data: data)
    }
}

/// RAW 冲洗：像修图软件的"基本"面板那样拖滑块，调好后送进图片编辑。
struct RawView: View {
    let name: String
    let data: Data
    var onClose: () -> Void
    var onEdit: (URL) -> Void

    @State private var model: RawModel
    @State private var toast: String?
    /// Mac：导出到文件。
    @State private var exportDoc: ImageFileDocument?
    @State private var exporting = false

    init(name: String, data: Data, onClose: @escaping () -> Void, onEdit: @escaping (URL) -> Void) {
        self.name = name
        self.data = data
        self.onClose = onClose
        self.onEdit = onEdit
        _model = State(initialValue: RawModel(name: name))
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if Platform.isMac {
                macLayout
            } else {
                VStack(spacing: 0) {
                    topBar.frame(height: 52)
                    canvas.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    panel
                    BottomTabBar(tabs: RawGroup.allCases, title: { $0.title }, selection: Binding(
                        get: { model.group },
                        set: { model.select(group: $0) }))
                }
            }
            if model.busy {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("正在按原始分辨率冲洗…").font(.system(size: 13)).foregroundStyle(.white)
                }
                .padding(24)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            }
            if let error = model.errorText {
                VStack(spacing: 14) {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                    Button("关闭", action: onClose).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 30)
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
                        .padding(.bottom, Platform.isMac ? 48 : 250)
                }
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .task { model.load(data: data) }
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: exportDoc?.type ?? .jpeg,
                      defaultFilename: (name as NSString).deletingPathExtension + "-RAW") { result in
            guard case .success = result else { return }
            if HistoryStore.shared.enabled, let doc = exportDoc {
                Task { await HistoryStore.shared.add(data: doc.data, ext: doc.type == .heic ? "heic" : "jpg", source: "RAW") }
            }
            show("已导出")
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.sizeText).font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            Spacer()
            Button { model.resetAll() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 44)
            }
            .opacity(model.isModified ? 1 : 0.35)
            .disabled(!model.isModified)
            .accessibilityLabel("全部复位")
            Button {
                Task {
                    guard let url = await model.develop() else {
                        show("冲洗失败")
                        return
                    }
                    let ok = (try? await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
                    }) != nil
                    if ok, HistoryStore.shared.enabled, let data = try? Data(contentsOf: url) {
                        let ext = url.pathExtension.lowercased()
                        await HistoryStore.shared.add(data: data, ext: ext == "jpeg" ? "jpg" : ext, source: "RAW")
                    }
                    show(ok ? "已保存到相册" : "保存失败，请检查相册权限")
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 44)
            }
            Button {
                Task {
                    if let url = await model.develop() { onEdit(url) } else { show("冲洗失败") }
                }
            } label: {
                Text("进入编辑")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .disabled(model.busy || model.preview == nil)
    }

    private var canvas: some View {
        ZoomableCanvas(image: model.shown, handlers: nil,
                       onTap: model.pickingWhiteBalance ? { point in model.pickWhiteBalance(at: point) } : nil)
            .overlay(alignment: .top) {
                if model.pickingWhiteBalance {
                    Text("点一下画面里本该是白色或灰色的地方")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(.top, 76)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let histogram = model.histogram {
                    Image(uiImage: histogram)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 128, height: 56)
                        .background(Color.black.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !Platform.isMac { phoneCompare }
            }
    }

    private var phoneCompare: some View {
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
    }

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 12) {
            if model.group == .optics {
                HStack(spacing: 8) {
                    Chip(title: "镜头校正", selected: model.lensCorrection && model.lensCorrectionSupported) {
                        model.setLensCorrection(!model.lensCorrection)
                    }
                    .opacity(model.lensCorrectionSupported ? 1 : 0.35)
                    .disabled(!model.lensCorrectionSupported)
                    Spacer()
                }
                Text(model.lensCorrectionSupported
                     ? "按文件里记录的镜头数据修正畸变、暗角和色差。想手动补暗角，用\u{201C}效果\u{201D}里的暗角往右拖。"
                     : "这个文件没有带镜头校正数据。想手动补暗角，用\u{201C}效果\u{201D}里的暗角往右拖。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                thirdRow
                let key = model.key
                HStack(spacing: 12) {
                    Text(key.format(model.value(key)))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 62, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(model.value(key)) },
                        set: { model.set(key, Float($0)) }
                    ), in: Double(key.range.lowerBound)...Double(key.range.upperBound))
                    Button { model.reset(key) } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(model.isChanged(key) ? Color.white : Theme.dim)
                            .frame(width: 36, height: 36)
                    }
                }
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(model.keys(in: model.group)) { item in
                            IconTile(symbol: item.symbol, title: item.title, selected: item == key,
                                     modified: model.isChanged(item)) {
                                model.key = item
                                model.pickingWhiteBalance = false
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
    }

    /// 三级菜单：白平衡预设、混色器的八个颜色、颜色分级的四个区。
    @ViewBuilder
    private var thirdRow: some View {
        switch model.group {
        case .color:
            HScroll {
                HRow(spacing: 8) {
                    Chip(title: "吸管", selected: model.pickingWhiteBalance) { model.pickingWhiteBalance.toggle() }
                    Chip(title: "原照设置", selected: !model.isChanged(.temperature) && !model.isChanged(.tint)) {
                        model.applyWhiteBalance(nil)
                    }
                    ForEach(WhiteBalancePreset.all) { preset in
                        Chip(title: preset.title,
                             selected: model.isChanged(.temperature) && model.value(.temperature) == preset.temperature
                                && model.value(.tint) == preset.tint) {
                            model.applyWhiteBalance(preset)
                        }
                    }
                }
            }
        case .mixer:
            HScroll {
                HRow(spacing: 8) {
                    ForEach(MixColor.allCases) { color in
                        Button { model.select(mixColor: color) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(color.swatch).frame(width: 12, height: 12)
                                Text(model.isChanged(mixColor: color) ? "\(color.title) •" : color.title)
                                    .font(.system(size: 14, weight: model.mixColor == color ? .semibold : .regular))
                                    .foregroundStyle(model.mixColor == color ? Color.black : Color.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(model.mixColor == color ? Color.white : Theme.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .grading:
            HStack(spacing: 8) {
                ForEach(GradeZone.allCases) { zone in
                    Chip(title: model.isChanged(gradeZone: zone) ? "\(zone.title) •" : zone.title,
                         selected: model.gradeZone == zone) { model.select(gradeZone: zone) }
                }
                Spacer()
            }
        default:
            EmptyView()
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toast = nil
        }
    }
}

// MARK: - Mac 布局

extension RawView {
    /// 顶栏 + （画布 | 右边的参数面板）。参数面板把这一组的滑条全部列出来，不用一个一个点。
    private var macLayout: some View {
        VStack(spacing: 0) {
            macTopBar
            Rectangle().fill(MacTheme.line).frame(height: 1)
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(MacTheme.canvas)
                Rectangle().fill(MacTheme.line).frame(width: 1)
                macInspector
                    .frame(width: 340)
                    .background(MacTheme.panel)
            }
        }
        .background(MacTheme.canvas)
    }

    private var macTopBar: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 70, height: 1)
            MacIconButton(symbol: "chevron.left", help: "返回开始页", action: onClose)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.sizeText).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
            }
            .padding(.leading, 4)
            Spacer()
            MacIconButton(symbol: "arrow.counterclockwise", help: "全部复位") { model.resetAll() }
                .disabled(!model.isModified)
            MacHoldButton(symbol: "square.split.2x1", help: "按住看原图") { model.comparing = $0 }
            Button {
                Task {
                    guard let url = await model.develop(), let data = try? Data(contentsOf: url) else {
                        show("冲洗失败")
                        return
                    }
                    exportDoc = ImageFileDocument(data: data, type: url.pathExtension.lowercased() == "heic" ? .heic : .jpeg)
                    exporting = true
                }
            } label: {
                Text("导出")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(MacTheme.line, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            Button {
                Task {
                    if let url = await model.develop() { onEdit(url) } else { show("冲洗失败") }
                }
            } label: {
                Text("进入编辑").macProminent()
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(MacTheme.chrome)
        .disabled(model.busy || model.preview == nil)
    }

    private var macInspector: some View {
        VStack(spacing: 0) {
            if let histogram = model.histogram {
                Image(uiImage: histogram)
                    .resizable()
                    .interpolation(.none)
                    .frame(height: 90)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(12)
            }
            // 分组：两行四个。
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(RawGroup.allCases) { group in
                    let on = model.group == group
                    Button { model.select(group: group) } label: {
                        Text(group.title)
                            .font(.system(size: 12, weight: on ? .bold : .regular))
                            .foregroundStyle(on ? Color.black : Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(on ? Theme.accent : MacTheme.header, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Rectangle().fill(MacTheme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.group == .optics {
                        panel
                    } else {
                        thirdRow
                        ForEach(model.keys(in: model.group)) { key in
                            macSlider(key)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func macSlider(_ key: RawKey) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(key.title)
                    .font(.system(size: 12))
                Spacer()
                Text(key.format(model.value(key)))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(model.isChanged(key) ? Theme.accent : Theme.dim)
                Button { model.reset(key) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .opacity(model.isChanged(key) ? 1 : 0.25)
                .disabled(!model.isChanged(key))
                .help("复位")
            }
            Slider(value: Binding(
                get: { Double(model.value(key)) },
                set: {
                    model.key = key
                    model.set(key, Float($0))
                }
            ), in: Double(key.range.lowerBound)...Double(key.range.upperBound))
            .controlSize(.small)
        }
    }
}
