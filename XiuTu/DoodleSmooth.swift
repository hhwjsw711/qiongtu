import CoreGraphics
import Foundation

/// 涂鸦的"自动圆润"：手指抬起后把这一笔修顺。
/// 画了个圈 → 变成圆 / 椭圆；差不多是直的 → 拉成直线；其余的 → 去掉手抖的小棱角，整体走势不变。
enum DoodleSmooth {
    /// points 是归一化坐标（原点左上角），size 是画布的宽高（只用比例）。
    static func process(_ points: [CGPoint], size: CGSize) -> [CGPoint] {
        guard points.count >= 3, size.width > 0, size.height > 0 else { return points }
        // 换到"长边 = 1"的等比例坐标里算，横竖图的圆都是圆。
        let long = max(size.width, size.height)
        let sx = size.width / long, sy = size.height / long
        let raw = points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
        let total = length(raw)
        guard total > 0.015 else { return points }
        let pts = resample(raw, count: max(24, min(240, Int(total / 0.004))))

        let out: [CGPoint]
        if let circle = ellipse(pts, total: total) {
            out = circle
        } else if let line = straight(pts) {
            out = line
        } else {
            out = smooth(pts)
        }
        return out.map { CGPoint(x: $0.x / sx, y: $0.y / sy) }
    }

    // MARK: 识别

    /// 首尾接上（或者画过头一点）、各点到中心的距离又比较一致：当成画了一个圈。
    private static func ellipse(_ pts: [CGPoint], total: CGFloat) -> [CGPoint]? {
        guard let first = pts.first, let last = pts.last else { return nil }
        // 首尾离得近，或者终点回到了起点附近（画过头）。
        var closeIndex = pts.count - 1
        if dist(first, last) > total * 0.2 {
            guard let i = pts.indices.dropFirst(pts.count / 2).first(where: { dist(pts[$0], first) < total * 0.08 }) else {
                return nil
            }
            closeIndex = i
        }
        let loop = Array(pts[0...closeIndex])
        let box = bounds(loop)
        guard box.width > 0.01, box.height > 0.01 else { return nil }
        var center = CGPoint(x: box.midX, y: box.midY)
        var rx = box.width / 2, ry = box.height / 2
        // 太扁的不当圈（多半是来回划了一下）。
        guard min(rx, ry) / max(rx, ry) > 0.28 else { return nil }
        // 各点的"椭圆半径"离 1 有多远。
        var errors: [CGFloat] = []
        for p in loop {
            let r = hypot((p.x - center.x) / rx, (p.y - center.y) / ry)
            errors.append(abs(r - 1))
        }
        let mean = errors.reduce(0, +) / CGFloat(errors.count)
        guard mean < 0.16, (errors.max() ?? 1) < 0.45 else { return nil }
        // 绕过的角度要接近一整圈，不然是一段弧线。
        var swept: CGFloat = 0
        for i in 1..<loop.count {
            let a0 = atan2(loop[i - 1].y - center.y, loop[i - 1].x - center.x)
            let a1 = atan2(loop[i].y - center.y, loop[i].x - center.x)
            var d = a1 - a0
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            swept += d
        }
        guard abs(swept) > 1.7 * .pi else { return nil }
        // 长宽差不多 → 正圆。
        if min(rx, ry) / max(rx, ry) > 0.85 {
            let r = (rx + ry) / 2
            rx = r
            ry = r
        }
        center = CGPoint(x: box.midX, y: box.midY)
        let start = atan2((first.y - center.y) / ry, (first.x - center.x) / rx)
        let dir: CGFloat = swept >= 0 ? 1 : -1
        let n = 96
        return (0...n).map { i in
            let a = start + dir * CGFloat(i) / CGFloat(n) * 2 * .pi
            return CGPoint(x: center.x + cos(a) * rx, y: center.y + sin(a) * ry)
        }
    }

    /// 每个点离首尾连线都很近：拉成直线。
    private static func straight(_ pts: [CGPoint]) -> [CGPoint]? {
        guard let a = pts.first, let b = pts.last else { return nil }
        let chord = dist(a, b)
        guard chord > 0.02 else { return nil }
        var worst: CGFloat = 0
        for p in pts {
            let d = abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / chord
            worst = max(worst, d)
        }
        return worst / chord < 0.045 ? [a, b] : nil
    }

    /// 来回几遍滑动平均：小抖动和小棱角没了，大的拐弯还在。首尾不动。
    private static func smooth(_ pts: [CGPoint]) -> [CGPoint] {
        var cur = pts
        let k = 3
        for _ in 0..<3 {
            var next = cur
            for i in 1..<(cur.count - 1) {
                let lo = max(0, i - k), hi = min(cur.count - 1, i + k)
                var x: CGFloat = 0, y: CGFloat = 0
                for j in lo...hi {
                    x += cur[j].x
                    y += cur[j].y
                }
                let n = CGFloat(hi - lo + 1)
                next[i] = CGPoint(x: x / n, y: y / n)
            }
            cur = next
        }
        return cur
    }

    // MARK: 小工具

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func length(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        return (1..<pts.count).reduce(0) { $0 + dist(pts[$1 - 1], pts[$1]) }
    }

    private static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 沿折线等距取 count 个点。
    private static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        let total = length(pts)
        guard total > 0, count > 1 else { return pts }
        let step = total / CGFloat(count - 1)
        var out = [pts[0]]
        var want = step
        var travelled: CGFloat = 0
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let d = dist(a, b)
            guard d > 0 else { continue }
            while want <= travelled + d, out.count < count - 1 {
                let u = (want - travelled) / d
                out.append(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
                want += step
            }
            travelled += d
        }
        out.append(pts[pts.count - 1])
        return out
    }
}
