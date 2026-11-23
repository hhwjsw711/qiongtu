import SwiftUI

// MARK: - 调色

/// 调色面板：上面是当前这一项的数值和滑块，下面一排是这一组的全部项目。
/// 分组（光效 / 色彩 / 细节 / 光影）在底部确认栏里切换，见 AdjustTitle。
struct AdjustPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        Group {
            if let sub = model.adjust.ui.sub {
                AdjustSubPanel(model: model, sub: sub)
            } else if Platform.isMac {
                macMain
            } else {
                main
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var main: some View {
        let key = model.adjustKey
        let items = model.adjustGroup.items
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("\(Int((model.adjust[key] * 100).rounded()))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(model.adjust[key]) },
                    set: { model.setAdjust(key, Float($0)) }
                ), in: key.bipolar ? -1...1 : 0...1)
                Button { model.setAdjust(key, 0) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(model.adjust[key] == 0 ? Theme.dim : Color.white)
                        .frame(width: 36, height: 36)
                }
            }
            HScroll {
                HRow(spacing: 8) {
                    ForEach(items) { item in
                        tile(item, selected: key)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            // 换组时回到最左边。
            .id(model.adjustGroup)
        }
    }

    /// Mac：这一组的滑条全部列出来；局部调色、HSL 这类子面板和 AI 项排在上面。
    private var macMain: some View {
        let items = model.adjustGroup.items
        let extras = items.filter { if case .key = $0 { return false } else { return true } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !extras.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 8) {
                        ForEach(extras) { item in macTile(item) }
                    }
                    Rectangle().fill(MacTheme.line).frame(height: 1)
                }
                ForEach(items) { item in
                    if case .key(let key) = item {
                        MacSliderRow(title: key.title,
                                     value: "\(Int((model.adjust[key] * 100).rounded()))",
                                     changed: model.adjust[key] != 0,
                                     binding: Binding(get: { Double(model.adjust[key]) },
                                                      set: {
                                                          model.adjustKey = key
                                                          model.setAdjust(key, Float($0))
                                                      }),
                                     range: key.bipolar ? -1...1 : 0...1) {
                            model.setAdjust(key, 0)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
            .padding(.trailing, 10)
        }
        .id(model.adjustGroup)
    }

    @ViewBuilder
    private func macTile(_ item: AdjustItem) -> some View {
        switch item {
        case .key:
            EmptyView()
        case .sub(let sub):
            IconTile(symbol: sub.symbol, title: sub.title, modified: model.adjust.isChanged(sub)) {
                model.setAdjustSub(sub)
            }
        case .ai(let ai):
            IconTile(symbol: ai.symbol, title: ai.title, badge: "AI") {
                model.startAIPreset(ai.preset, group: .fix)
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: AdjustItem, selected: AdjustKey) -> some View {
        switch item {
        case .key(let key):
            IconTile(symbol: key.symbol, title: key.title,
                     selected: key == selected, modified: model.adjust[key] != 0) {
                model.adjustKey = key
            }
        case .sub(let sub):
            IconTile(symbol: sub.symbol, title: sub.title, modified: model.adjust.isChanged(sub)) {
                model.setAdjustSub(sub)
            }
            if sub == .local {
                // 局部调色和后面整张图的调节之间隔一条线。
                Rectangle().fill(Theme.chip).frame(width: 1, height: 34)
            }
        case .ai(let ai):
            IconTile(symbol: ai.symbol, title: ai.title, badge: "AI") {
                model.startAIPreset(ai.preset, group: .fix)
            }
        }
    }
}

/// 调色时底部确认栏（✕ 和 ✓ 之间）显示的内容：四个分组的标签；进了子面板就显示子面板的名字。
struct AdjustTitle: View {
    @Bindable var model: EditorModel

    var body: some View {
        if let sub = model.adjust.ui.sub {
            Text(sub.title).font(.system(size: 15, weight: .semibold))
        } else {
            UnderlineTabs(items: AdjustGroup.allCases, selected: model.adjustGroup, title: { $0.title }) { group in
                guard group != model.adjustGroup else { return }
                model.adjustGroup = group
                if let first = group.keys.first { model.adjustKey = first }
            }
        }
    }
}
