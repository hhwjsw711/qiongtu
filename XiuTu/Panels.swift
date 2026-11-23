import SwiftUI

// MARK: - 裁剪

struct CropPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("\(Int(model.crop.straighten.rounded()))°")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(model.crop.straighten) },
                    set: { model.setStraighten(CGFloat($0)) }
                ), in: -30...30)
                Button { model.resetCrop() } label: {
                    Text("还原")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.crop.isIdentity ? Theme.dim : Color.white)
                        .frame(height: 36)
                }
            }
            HStack(spacing: 4) {
                IconTile(symbol: "rotate.right", title: "旋转") { model.cropRotate() }
                IconTile(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", title: "水平翻转") {
                    model.cropFlipHorizontal()
                }
                IconTile(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", title: "垂直翻转") {
                    model.cropFlipVertical()
                }
                Spacer()
            }
            HScroll {
                HRow(spacing: 8) {
                    ForEach(CropAspect.allCases) { aspect in
                        Chip(title: aspect.title, selected: model.cropAspect == aspect) {
                            model.setCropAspect(aspect)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

// MARK: - 马赛克

struct MosaicPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            sliderRow(title: "大小", value: $model.brushSize, range: 12...90)
            sliderRow(title: "强度", value: $model.mosaicStrength, range: 0.05...1)
            HStack(spacing: 4) {
                ForEach(MosaicStyle.allCases) { style in
                    IconTile(symbol: style.symbol, title: style.title,
                             selected: !model.erasing && model.mosaicStyle == style) {
                        model.mosaicStyle = style
                        model.erasing = false
                    }
                }
                Spacer()
                IconTile(symbol: "eraser", title: "橡皮", selected: model.erasing) {
                    model.erasing.toggle()
                }
                IconTile(symbol: "arrow.uturn.backward", title: "撤销一笔") {
                    model.undoStroke()
                }
                .opacity(model.mosaic.strokes.isEmpty ? 0.35 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func sliderRow(title: String, value: Binding<CGFloat>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = CGFloat($0) }),
                   in: range)
        }
    }
}
