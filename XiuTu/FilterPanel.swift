import SwiftUI

// MARK: - 滤镜

struct FilterPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            // 拍立得有自己的强度，不用上面这条。
            if model.lookCategory != .instant {
            HStack(spacing: 12) {
                Text("\(Int((model.lookIntensity * 100).rounded()))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(model.lookIntensity) },
                    set: {
                        model.lookIntensity = CGFloat($0)
                        model.renderLook()
                    }
                ), in: 0...1)
            }
            .opacity(model.lookID == nil ? 0.3 : 1)
            .disabled(model.lookID == nil)
            }

            HScroll {
                HRow(spacing: 8) {
                    ForEach(LookCategory.allCases) { category in
                        Chip(title: category.title, selected: model.lookCategory == category) {
                            model.lookCategory = category
                        }
                    }
                }
            }
            if model.lookCategory == .master {
                HScroll {
                    HRow(alignment: .top, spacing: 10) {
                        ForEach(AIPresetGroup.master.presets) { preset in
                            ImageTile(title: preset.title, image: model.masterThumbs[preset.title],
                                      symbol: "camera.aperture", badge: "AI") { model.startMaster(preset) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .task { model.prepareMasterThumbs() }
            } else if model.lookCategory == .instant {
                InstantFilmRow(model: model)
            } else {
                HScroll {
                    HRow(spacing: 10) {
                        thumb(name: "原图", image: model.lookThumbOriginal, selected: model.lookID == nil) {
                            model.selectLook(nil)
                        }
                        ForEach(FilmLook.all.filter { $0.category == model.lookCategory }) { look in
                            thumb(name: look.name, image: model.lookThumbs[look.id], selected: model.lookID == look.id) {
                                model.selectLook(look.id)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func thumb(name: String, image: UIImage?, selected: Bool, action: @escaping () -> Void) -> some View {
        ImageTile(title: name, image: image, selected: selected, action: action)
    }
}
