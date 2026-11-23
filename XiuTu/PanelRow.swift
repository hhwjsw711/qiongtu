import SwiftUI

/// 面板里一排横着的选项：手机上屏幕窄，左右滑；Mac 上面板够宽，不滑，直接换行铺满。
/// 用法和原来一样：HScroll { HRow(spacing: 8) { ... } }。
struct HScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if Platform.isMac {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
    }
}

struct HRow<Content: View>: View {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if Platform.isMac {
            FlowLayout(spacing: spacing ?? 8, alignment: alignment) { content }
        } else {
            HStack(alignment: alignment, spacing: spacing) { content }
        }
    }
}

/// 从左到右排，一行放不下就换到下一行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: VerticalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let grid = grid(width: proposal.width, subviews: subviews) {
            return CGSize(width: proposal.width ?? 0, height: grid.height)
        }
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let grid = grid(width: bounds.width, subviews: subviews) {
            // 等宽格子：每一格一样宽，整行铺满，标签按钮拉满格子，别的放在格子中间。
            for (index, subview) in subviews.enumerated() {
                let row = index / grid.columns, col = index % grid.columns
                let x = bounds.minX + CGFloat(col) * (grid.cell + spacing)
                let y = bounds.minY + grid.rowTops[row]
                subview.place(at: CGPoint(x: x + grid.cell / 2, y: y + grid.rowHeights[row] / 2), anchor: .center,
                              proposal: ProposedViewSize(width: grid.cell, height: grid.rowHeights[row]))
            }
            return
        }
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                let dy: CGFloat
                switch alignment {
                case .top: dy = 0
                case .bottom: dy = row.height - size.height
                default: dy = (row.height - size.height) / 2
                }
                subviews[index].place(at: CGPoint(x: x, y: y + dy), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Grid {
        let columns: Int
        let cell: CGFloat
        let rowTops: [CGFloat]
        let rowHeights: [CGFloat]
        var height: CGFloat { (rowTops.last ?? 0) + (rowHeights.last ?? 0) }
    }

    /// 宽度差不多的一组（比如一排标签）排成等宽的格子，比参差不齐地换行好看；宽窄差太多的就照常换行。
    private func grid(width: CGFloat?, subviews: Subviews) -> Grid? {
        guard let width, width.isFinite, width > 0, subviews.count >= 3 else { return nil }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widest = sizes.map(\.width).max() ?? 0
        let narrowest = sizes.map(\.width).min() ?? 0
        guard widest > 0, narrowest > 0, widest <= narrowest * 2.2, widest <= width else { return nil }
        let columns = max(1, Int((width + spacing) / (widest + spacing)))
        guard columns >= 2 else { return nil }
        let cell = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: sizes.count, by: columns) {
            let h = sizes[start..<min(start + columns, sizes.count)].map(\.height).max() ?? 0
            tops.append(y)
            heights.append(h)
            y += h + spacing
        }
        return Grid(columns: columns, cell: cell, rowTops: tops, rowHeights: heights)
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let next = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
