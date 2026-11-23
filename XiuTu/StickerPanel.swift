import PhotosUI
import SwiftUI

// MARK: - 贴纸

/// 贴纸面板：我的贴纸（相册导入、AI 生成）、内置的图形和标签，以及表情。
/// 面板上不放说明文字，只显示按钮、进行中的状态和出错原因。
struct StickerPanel: View {
    @Bindable var model: EditorModel

    private enum Category: Hashable {
        case mine, shapes, labels
        case emoji(Int)
    }

    @State private var category: Category = .shapes
    @State private var picking = false
    @State private var busy = false
    @State private var problem: String?
    @State private var showAI = false
    @AppStorage("xiutu.sticker.autoCut") private var autoCut = true
    @Environment(\.displayScale) private var screenScale

    private let store = StickerStore.shared

    private static let sets: [(title: String, items: [String])] = [
        ("表情", ["😀", "😂", "🥹", "😍", "😎", "🥳", "😭", "😡", "🤔", "😴", "🤯", "🥺", "😇", "🤪", "😱", "🫠"]),
        ("爱心", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💖", "💘", "💝", "💕", "💔", "❣️", "💋", "🫶"]),
        ("手势", ["👍", "👎", "👌", "✌️", "🤞", "🤟", "🤘", "👏", "🙌", "🙏", "💪", "👋", "🤙", "👉", "👆", "✊"]),
        ("自然", ["🌸", "🌹", "🌻", "🌈", "⭐️", "🌙", "☀️", "☁️", "❄️", "🔥", "💧", "🍀", "🌊", "⚡️", "🍁", "🌴"]),
        ("美食", ["🍰", "🍓", "🍑", "🍒", "🍉", "🍔", "🍕", "🍜", "🍣", "🍩", "🍦", "🧋", "☕️", "🍺", "🥂", "🍷"]),
        ("符号", ["✨", "💯", "💢", "💤", "💬", "❗️", "❓", "✅", "❌", "⭕️", "🎀", "🎉", "🎈", "👑", "💎", "🎵"]),
    ]

    /// 内置的文字标签：加到画面上以后还是文字，双击可以改内容。
    private static let labels: [OverlayItem] = {
        func make(_ text: String, font: String = OverlayItem.defaultFontID, _ configure: (inout OverlayItem) -> Void) -> OverlayItem {
            var item = OverlayItem(text: text)
            item.size = 0.085
            item.fontID = font
            configure(&item)
            return item
        }
        let red = OverlayColor(0.9, 0.16, 0.2), yellow = OverlayColor(1.0, 0.84, 0.04), pink = OverlayColor(1.0, 0.45, 0.7)
        let navy = OverlayColor(0.12, 0.2, 0.5), blue = OverlayColor(0.04, 0.52, 1.0), mint = OverlayColor(0.55, 0.9, 0.78)
        return [
            make("OOTD", font: "AvenirNext-Heavy") { $0.color = .white; $0.boxOn = true; $0.boxColor = .black; $0.boxShape = .capsule },
            make("打卡", font: "sys.black") { $0.color = .white; $0.boxOn = true; $0.boxColor = red; $0.boxShape = .tag },
            make("今日份快乐", font: "sys.rounded") { $0.color = .black; $0.boxOn = true; $0.boxColor = yellow; $0.boxShape = .marker },
            make("Yummy!", font: "MarkerFelt-Wide") { $0.color = .black; $0.boxOn = true; $0.boxColor = .white; $0.boxShape = .bubble },
            make("周末愉快", font: "sys.rounded") {
                $0.color = pink; $0.strokeOn = true; $0.strokeColor = .white; $0.strokeWidth = 0.7
                $0.shadowOn = true; $0.shadowColor = pink; $0.shadowOpacity = 0.5; $0.shadowBlur = 0.5; $0.shadowDistance = 0.1; $0.shadowAngle = 90
            },
            make("NEW", font: "Futura-CondensedExtraBold") { $0.color = .white; $0.italic = true; $0.boxOn = true; $0.boxColor = red; $0.boxShape = .slant },
            make("Vlog", font: "SnellRoundhand-Bold") { $0.color = .white; $0.glowOn = true; $0.glowColor = OverlayColor(1.0, 0.3, 0.65); $0.glowStrength = 0.8 },
            make("好吃", font: "sys.black") {
                $0.color = yellow; $0.strokeOn = true; $0.strokeColor = .black; $0.strokeWidth = 0.6
                $0.shadowOn = true; $0.shadowBlur = 0; $0.shadowDistance = 0.22; $0.shadowAngle = 45; $0.shadowOpacity = 1
            },
            make("Hello", font: "Didot-Bold") { $0.color = .white; $0.boxOn = true; $0.boxColor = navy; $0.boxShape = .ribbon },
            make("LOVE", font: "Futura-Bold") { $0.color = red; $0.letterSpacing = 0.2; $0.boxOn = true; $0.boxColor = .white; $0.boxShape = .rounded },
            make("出发", font: "sys.black") { $0.color = .white; $0.italic = true; $0.boxOn = true; $0.boxColor = blue; $0.boxShape = .slant },
            make("谢谢", font: "sys.rounded") { $0.color = .black; $0.boxOn = true; $0.boxColor = mint; $0.boxShape = .bubble },
            make("Mood", font: "Menlo-Bold") { $0.color = .white; $0.boxOn = true; $0.boxColor = .black; $0.boxOpacity = 0.6; $0.boxShape = .rounded },
            make("生日快乐", font: "sys.rounded") { $0.color = .white; $0.boxOn = true; $0.boxColor = pink; $0.boxShape = .ellipse },
            make("SALE", font: "HelveticaNeue-CondensedBlack") { $0.color = .black; $0.boxOn = true; $0.boxColor = yellow; $0.boxShape = .rect },
            make("晚安", font: "sys.serif") { $0.color = .white; $0.glowOn = true; $0.glowColor = OverlayColor(0.2, 0.7, 1.0); $0.glowStrength = 0.7 },
        ]
    }()

    private let rows = [GridItem(.fixed(46), spacing: 6), GridItem(.fixed(46), spacing: 6)]

    var body: some View {
        VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 8) {
                    Chip(title: "我的", selected: category == .mine) { category = .mine }
                    Chip(title: "图形", selected: category == .shapes) { category = .shapes }
                    Chip(title: "标签", selected: category == .labels) { category = .labels }
                    ForEach(Self.sets.indices, id: \.self) { index in
                        Chip(title: Self.sets[index].title, selected: category == .emoji(index)) { category = .emoji(index) }
                    }
                }
            }
            .padding(.horizontal, Platform.isMac ? 0 : -16)
            .contentMargins(.horizontal, 16, for: .scrollContent)

            if Platform.isMac {
                // Mac：面板高，竖着排、往下滚。
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) { grid }
                }
                .frame(height: 340)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: rows, spacing: 6) { grid }
                }
                .frame(height: 98)
                .padding(.horizontal, Platform.isMac ? 0 : -16)
                .contentMargins(.horizontal, 16, for: .scrollContent)
            }

            footer.frame(height: 34)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .imageSource(isPresented: $picking) { items in
            if let item = items.first { importPhoto(item) }
        }
        .sheet(isPresented: $showAI) {
            AIStickerSheet { image in
                category = .mine
                model.addOverlay(image: image)
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var grid: some View {
        switch category {
        case .mine:
            Button { picking = true } label: {
                actionTile("photo.badge.plus", Platform.isMac ? "打开图片" : "相册")
            }
            .buttonStyle(.plain)
            Button { showAI = true } label: { actionTile("sparkles", "AI 生成") }
                .buttonStyle(.plain)
            ForEach(store.items) { entry in
                Button {
                    if let image = store.image(for: entry) { model.addOverlay(image: image) }
                } label: {
                    imageTile(entry.thumb)
                }
                .buttonStyle(PressStyle())
                .contextMenu {
                    Button("删除", role: .destructive) { store.delete(entry) }
                }
            }
        case .shapes:
            ForEach(StickerArt.all) { piece in
                Button {
                    if let image = StickerArt.image(piece, size: 1024) { model.addOverlay(image: image, dieCut: true) }
                } label: {
                    imageTile(StickerArt.image(piece, size: 128).map { UIImage(cgImage: $0) })
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(piece.title)
            }
        case .labels:
            ForEach(Self.labels.indices, id: \.self) { index in
                let label = Self.labels[index]
                Button { model.addOverlay(item: label) } label: {
                    labelTile(label, key: "label-\(index)")
                }
                .buttonStyle(PressStyle())
            }
        case .emoji(let index):
            ForEach(Self.sets[index].items, id: \.self) { emoji in
                Button { model.addOverlay(text: emoji, sticker: true) } label: {
                    Text(emoji)
                        .font(.system(size: 30))
                        .frame(width: 46, height: 46)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 最下面一行：选中图片贴纸时是它的样式，否则在"我的"里是导入选项和状态。
    @ViewBuilder
    private var footer: some View {
        if let item = model.selectedOverlay, item.isImage {
            HStack(spacing: 8) {
                Chip(title: "白边", selected: item.strokeOn) {
                    model.updateOverlay(item.id) {
                        $0.strokeOn.toggle()
                        $0.strokeColor = .white
                    }
                }
                Chip(title: "阴影", selected: item.shadowOn) {
                    model.updateOverlay(item.id) {
                        $0.shadowOn.toggle()
                        $0.shadowColor = .black
                        $0.shadowOpacity = 0.4
                        $0.shadowBlur = 0.6
                        $0.shadowDistance = 0.25
                        $0.shadowAngle = 90
                    }
                }
                MiniSlider(title: "透明度", value: item.opacity, range: 0.1...1, labelWidth: 40) { v in
                    model.updateOverlay(item.id) { $0.opacity = v }
                }
            }
        } else if category == .mine {
            HStack(spacing: 10) {
                Chip(title: "自动抠图", symbol: "scissors", selected: autoCut) { autoCut.toggle() }
                if busy {
                    ProgressView().tint(.white)
                    Text("正在处理…").font(.system(size: 13))
                } else if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        } else {
            Color.clear
        }
    }

    private func actionTile(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .frame(width: 46, height: 46)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func imageTile(_ image: UIImage?) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(5)
            }
        }
        .frame(width: 46, height: 46)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func labelTile(_ label: OverlayItem, key: String) -> some View {
        let image = OverlayThumbs.image(key: key, fontSize: 15 * screenScale) { label }
        let size = image.map { CGSize(width: $0.size.width / screenScale, height: $0.size.height / screenScale) } ?? .zero
        let fit = min(1, 38 / max(size.height, 1))
        return ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width * fit, height: size.height * fit)
            }
        }
        .frame(width: max(46, size.width * fit + 8), height: 46)
        .background(Color(white: 0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func importPhoto(_ item: @escaping ImageLoader) {
        guard !busy else { return }
        busy = true
        problem = nil
        let cut = autoCut
        Task {
            defer { busy = false }
            guard let data = await item(),
                  let made = await StickerImport.make(from: data, autoCut: cut) else {
                problem = "这张图读不出来"
                return
            }
            guard store.add(made.image) != nil else {
                problem = "保存失败"
                return
            }
            model.addOverlay(image: made.image)
            if made.cutFailed { problem = "没识别出主体，整张加进来了" }
        }
    }
}

// MARK: - AI 生成贴纸

/// 写一句想要什么，用设置里选的服务商生成一张贴纸，存进"我的贴纸"。
struct AIStickerSheet: View {
    var onUse: (CGImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var what = ""
    @State private var style = 0
    @State private var running = false
    @State private var started = Date()
    @State private var error: String?
    @State private var result: CGImage?
    @State private var task: Task<Void, Never>?
    @State private var showSettings = false
    @FocusState private var focused: Bool

    private let settings = AISettings.shared

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("AI 生成贴纸").font(.system(size: 17, weight: .bold))
                Spacer()
                ProviderMenu(openSettings: { showSettings = true }, compact: true)
            }
            if !settings.isConfigured(settings.active) {
                NeedsKeyView(openSettings: { showSettings = true })
            } else {
                TextField("想要什么贴纸", text: $what, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...3)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(StickerAI.styles.indices, id: \.self) { index in
                            Chip(title: StickerAI.styles[index].title, selected: style == index) { style = index }
                        }
                    }
                }
                if let result {
                    Image(uiImage: UIImage(cgImage: result))
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                        .background(Color(white: 0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if running {
                    HStack(spacing: 12) {
                        ProgressView().tint(.white)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                            Text("\(settings.active.shortTitle) 正在生成… \(seconds) 秒")
                                .font(.system(size: 14))
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("取消") { cancel() }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(height: 44)
                } else {
                    HStack(spacing: 10) {
                        if let result {
                            bigButton("加到画面", symbol: "plus", primary: true) {
                                onUse(result)
                                dismiss()
                            }
                        }
                        bigButton(result == nil ? "生成" : "再生成", symbol: result == nil ? "sparkles" : "arrow.clockwise",
                                  primary: result == nil, action: generate)
                            .opacity(trimmed.isEmpty ? 0.4 : 1)
                            .disabled(trimmed.isEmpty)
                    }
                }
                AIFailureView(message: error, retry: generate)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .foregroundStyle(.white)
        .background(Theme.panel.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { focused = true }
        .onDisappear { task?.cancel() }
    }

    private var trimmed: String { what.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func bigButton(_ title: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primary ? Color.black : Color.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(primary ? Theme.accent : Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func generate() {
        let text = trimmed
        guard !text.isEmpty, !running else { return }
        focused = false
        error = nil
        running = true
        started = Date()
        let hint = StickerAI.styles[style].prompt
        task = Task {
            do {
                let made = try await StickerAI.generate(what: text, style: hint)
                guard !Task.isCancelled else { return }
                result = made.image
                StickerStore.shared.add(made.image)
            } catch is CancellationError {
                // 用户取消了
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            running = false
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        running = false
    }
}
