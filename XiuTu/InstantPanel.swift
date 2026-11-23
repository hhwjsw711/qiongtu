import SwiftUI

/// 滤镜面板选到"拍立得"这一类时显示的内容：上面一排相纸（用当前照片做的缩略图），下面是色调、相纸颜色、取景这些调节。
struct InstantFilmRow: View {
    @Bindable var model: EditorModel

    private enum Tab: String, CaseIterable, Identifiable {
        case stock, strength, paper, framing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stock: return "色调"
            case .strength: return "强度"
            case .paper: return "相纸"
            case .framing: return "取景"
            }
        }
    }

    @State private var tab: Tab = .stock
    @State private var editingCaption = false
    @State private var draft = ""

    var body: some View {
        let params = model.instantState.params
        let on = !params.isIdentity
        VStack(spacing: 10) {
            HScroll {
                HRow(alignment: .top, spacing: 10) {
                    ImageTile(title: "无", image: model.lookThumbOriginal, selected: !on) {
                        model.selectInstant(nil)
                    }
                    ForEach(InstantPreset.all) { preset in
                        ImageTile(title: preset.title, image: model.instantState.thumbs[preset.id],
                                  selected: on && params.format == preset.format && params.rotated == preset.rotated,
                                  symbol: "photo") {
                            model.selectInstant(preset)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Group {
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(Tab.allCases) { item in
                            Chip(title: item.title, selected: tab == item) { tab = item }
                        }
                        Rectangle().fill(Theme.chip).frame(width: 1, height: 20)
                        Chip(title: "写字", symbol: "pencil", selected: !params.caption.isEmpty) {
                            draft = params.caption.isEmpty ? Self.today() : params.caption
                            editingCaption = true
                        }
                        Chip(title: "旋转", symbol: "rotate.right", selected: false) {
                            model.updateInstant {
                                $0.rotated.toggle()
                                $0.shift = 0
                            }
                        }
                        Chip(title: "实物", symbol: "scanner", selected: params.real) {
                            model.updateInstant { $0.real.toggle() }
                        }
                        if params.real {
                            // 扫描台的颜色。
                            ForEach(InstantBed.allCases) { bed in
                                Button {
                                    model.updateInstant { $0.bed = bed }
                                } label: {
                                    Circle()
                                        .fill(bed.color.color)
                                        .frame(width: 24, height: 24)
                                        .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                                        .padding(3)
                                        .overlay(Circle().stroke(params.bed == bed ? Theme.accent : Color.clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(bed.title)
                            }
                        } else {
                            Chip(title: "投影", symbol: "shadow", selected: params.shadow) {
                                model.updateInstant { $0.shadow.toggle() }
                            }
                        }
                    }
                }
                control(params)
                    .frame(height: 36)
            }
            .opacity(on ? 1 : 0.3)
            .disabled(!on)
        }
        .task { model.prepareInstantThumbs() }
        .alert("相纸上的字", isPresented: $editingCaption) {
            TextField("", text: $draft)
            Button("确定") {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                model.updateInstant { $0.caption = text }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func control(_ params: InstantParams) -> some View {
        switch tab {
        case .stock:
            HScroll {
                HRow(spacing: 8) {
                    ForEach(InstantStock.allCases) { stock in
                        Chip(title: stock.title, selected: params.stock == stock) {
                            model.updateInstant { $0.stock = stock }
                        }
                    }
                }
            }
        case .strength:
            FrameSliderRow(value: params.intensity) { value in
                model.updateInstant { $0.intensity = value }
            }
        case .paper:
            HScroll {
                HRow(spacing: 8) {
                    FrameColorWell(color: params.paper) { color in
                        model.updateInstant { $0.paper = color }
                    }
                    ForEach(InstantPaper.all, id: \.self) { item in
                        Button {
                            model.updateInstant { $0.paper = item }
                        } label: {
                            Circle()
                                .fill(item.color)
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().stroke(params.paper == item ? Theme.accent : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        case .framing:
            FrameSliderRow(value: params.shift, range: -1...1, text: "\(Int((params.shift * 100).rounded()))") { value in
                // 靠近正中时吸过去。
                model.updateInstant { $0.shift = abs(value) < 0.04 ? 0 : value }
            }
        }
    }

    /// 今天的日期，写成相纸上常见的样子。
    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter.string(from: Date())
    }
}
