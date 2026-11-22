import SwiftUI
import UIKit

extension EditorModel {
    // MARK: 文字 / 贴纸

    /// 新加的项稍微错开一点，不会正好叠在上一个上面。
    private func place(_ item: inout OverlayItem) {
        let n = CGFloat(overlayItems.count % 5)
        item.center = CGPoint(x: 0.5 + n * 0.03, y: 0.5 + n * 0.03)
    }

    @discardableResult
    func addOverlay(text: String, sticker: Bool) -> UUID {
        var item = OverlayItem(text: text, isSticker: sticker)
        item.size = sticker ? 0.18 : 0.07
        if !sticker, let last = overlayItems.last(where: { !$0.isSticker }) {
            // 接着用上一段文字的字体和样式，不用每次重新调。
            var styled = last
            styled.id = item.id
            styled.text = text
            styled.scale = 1
            styled.rotation = 0
            styled.size = item.size
            item = styled
        }
        place(&item)
        overlayItems.append(item)
        selectedOverlayID = item.id
        return item.id
    }

    /// 加一张图片贴纸。dieCut = true 时带白边和一点阴影，像真的贴纸。
    @discardableResult
    func addOverlay(image: CGImage, dieCut: Bool = false) -> UUID {
        var item = OverlayItem(text: OverlayItem.imagePlaceholder, isSticker: true)
        item.image = OverlayImage(cg: image)
        // 宽度占画面的三成左右；特别瘦高的图再小一点。
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        item.size = aspect < 0.7 ? 0.22 : 0.3
        if dieCut {
            item.strokeOn = true
            item.strokeColor = .white
            item.strokeWidth = 0.5
            item.shadowOn = true
            item.shadowColor = .black
            item.shadowOpacity = 0.4
            item.shadowBlur = 0.6
            item.shadowDistance = 0.25
            item.shadowAngle = 90
        }
        place(&item)
        overlayItems.append(item)
        selectedOverlayID = item.id
        return item.id
    }

    /// 加一个已经配好样式的项（标签贴纸用）。
    @discardableResult
    func addOverlay(item template: OverlayItem) -> UUID {
        var item = template
        item.id = UUID()
        item.scale = 1
        item.rotation = 0
        place(&item)
        overlayItems.append(item)
        selectedOverlayID = item.id
        return item.id
    }

    /// 加一个形状。默认是一条半透明的黑色横条（做字幕条、标签底最常用）。
    @discardableResult
    func addGraphic(_ kind: GraphicKind) -> UUID {
        var item = OverlayItem(text: OverlayItem.imagePlaceholder, isSticker: true)
        var g = GraphicStyle(kind: kind)
        switch kind {
        case .rect: g.aspect = 0.22; item.size = 0.8; item.color = .black; item.opacity = 0.6
        case .arrow: g.aspect = 0.45; item.size = 0.4; item.color = OverlayColor(1.0, 0.27, 0.27)
        case .bubble: g.aspect = 0.7; item.size = 0.45; item.color = .white
        default: g.aspect = 1; item.size = 0.35; item.color = OverlayColor(1.0, 0.84, 0.04)
        }
        if kind == .star { g.sides = 5 }
        item.graphic = g
        place(&item)
        overlayItems.append(item)
        selectedOverlayID = item.id
        return item.id
    }

    func updateOverlay(_ id: UUID, _ change: (inout OverlayItem) -> Void) {
        guard let i = overlayItems.firstIndex(where: { $0.id == id }) else { return }
        change(&overlayItems[i])
    }

    func removeOverlay(_ id: UUID) {
        overlayItems.removeAll { $0.id == id }
        if selectedOverlayID == id { selectedOverlayID = nil }
    }

    /// 复制一份，放在旁边并选中。
    func duplicateOverlay(_ id: UUID) {
        guard let source = overlayItems.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.center = CGPoint(x: min(source.center.x + 0.05, 1.05), y: min(source.center.y + 0.05, 1.05))
        overlayItems.append(copy)
        selectedOverlayID = copy.id
    }

    var selectedOverlay: OverlayItem? {
        guard let id = selectedOverlayID else { return nil }
        return overlayItems.first { $0.id == id }
    }
}
