import CoreGraphics
import Foundation

/// 妆容笔能画的范围：按识别到的五官算出来，眉笔只落在眉毛上、口红只落在嘴唇上……
/// 结果是归一化坐标（原点左上角）的多边形；每一块的第一圈是外轮廓，后面的是挖掉的洞。
enum DoodleFaceRegion {
    /// size 是图片宽高（只用比例）。返回 (范围, 羽化宽度——以图片长边为 1)。
    static func region(for brush: DoodleBrush, faces: [FaceInfo], size: CGSize) -> (shapes: [[[CGPoint]]], feather: CGFloat) {
        guard size.width > 0, size.height > 0 else { return ([], 0) }
        let long = max(size.width, size.height)
        let sx = size.width / long, sy = size.height / long
        // 在"长边 = 1"的等比例坐标里算，算完换回去。
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        func back(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / sx, y: p.y / sy) }

        var shapes: [[[CGPoint]]] = []
        var feather: CGFloat = 0
        for face in faces where face.hasReliableLandmarks {
            let lEye = face.leftEye.map(m), rEye = face.rightEye.map(m)
            let lBrow = face.leftBrow.map(m), rBrow = face.rightBrow.map(m)
            let outer = face.outerLips.map(m), inner = face.innerLips.map(m)
            let contour = face.contour.map(m)
            let eyeW = max(width(lEye), width(rEye), 0.005)
            let faceW = max(width(contour), eyeW * 3)
            var parts: [[[CGPoint]]] = []
            switch brush {
            case .brow:
                for brow in [lBrow, rBrow] where brow.count >= 2 {
                    parts.append([band(brow, half: eyeW * 0.17)])
                }
                feather = max(feather, eyeW * 0.08)
            case .eyeliner:
                // 眼睛一圈：外面放大一点，里面挖掉眼球，只剩睫毛根那一圈。
                for eye in [lEye, rEye] where eye.count >= 3 {
                    parts.append([scaled(hull(eye), 1.3, widen: 1.12), scaled(hull(eye), 0.82)])
                }
                feather = max(feather, eyeW * 0.05)
            case .eyeshadow:
                // 眼睛和眉毛之间：眼睛的点 + 往眼睛那边收一半的眉毛点，挖掉眼球。
                for (eye, brow) in [(lEye, lBrow), (rEye, rBrow)] where eye.count >= 3 && brow.count >= 2 {
                    let c = centroid(eye)
                    let lifted = brow.map { CGPoint(x: c.x + ($0.x - c.x) * 0.85, y: c.y + ($0.y - c.y) * 0.62) }
                    parts.append([scaled(hull(eye + lifted), 1.12), scaled(hull(eye), 0.9)])
                }
                feather = max(feather, eyeW * 0.14)
            case .blush:
                // 两边颧骨下面各一块椭圆。
                guard lEye.count >= 3, rEye.count >= 3 else { break }
                let mouthY = outer.isEmpty ? centroid(lEye + rEye).y + eyeW * 1.5 : centroid(outer).y
                for eye in [lEye, rEye] {
                    let c = centroid(eye)
                    let other = centroid(eye == lEye ? rEye : lEye)
                    let outward: CGFloat = c.x < other.x ? -1 : 1
                    let center = CGPoint(x: c.x + outward * faceW * 0.07, y: c.y + (mouthY - c.y) * 0.5)
                    parts.append([ellipse(center, rx: faceW * 0.15, ry: faceW * 0.11)])
                }
                feather = max(feather, faceW * 0.06)
            case .lip:
                guard outer.count >= 3 else { break }
                var shape = [scaled(hull(outer), 1.04)]
                // 张着嘴时挖掉嘴里，不涂到牙齿上。
                if inner.count >= 3, area(hull(inner)) > area(hull(outer)) * 0.15 { shape.append(hull(inner)) }
                parts.append(shape)
                feather = max(feather, eyeW * 0.04)
            case .glow:
                // 整张脸：下颌轮廓 + 往上抬到额头的眉毛。
                guard contour.count >= 3 else { break }
                let up = (lBrow + rBrow).map { CGPoint(x: $0.x, y: $0.y - faceW * 0.22) }
                parts.append([hull(contour + up)])
                feather = max(feather, faceW * 0.04)
            default:
                break
            }
            shapes += parts
        }
        let converted = shapes.map { $0.map { $0.map(back) } }
        return (converted, feather)
    }

    // MARK: 几何

    private static func width(_ pts: [CGPoint]) -> CGFloat {
        guard let a = pts.map(\.x).min(), let b = pts.map(\.x).max() else { return 0 }
        return b - a
    }

    private static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    /// 以重心为中心放大 / 缩小；widen 额外把左右拉长一点（眼尾要能拉出眼线）。
    private static func scaled(_ pts: [CGPoint], _ k: CGFloat, widen: CGFloat = 1) -> [CGPoint] {
        let c = centroid(pts)
        return pts.map { CGPoint(x: c.x + ($0.x - c.x) * k * widen, y: c.y + ($0.y - c.y) * k) }
    }

    private static func ellipse(_ c: CGPoint, rx: CGFloat, ry: CGFloat) -> [CGPoint] {
        (0..<32).map { i in
            let a = CGFloat(i) / 32 * 2 * .pi
            return CGPoint(x: c.x + cos(a) * rx, y: c.y + sin(a) * ry)
        }
    }

    private static func area(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 3 else { return 0 }
        var s: CGFloat = 0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// 凸包（单调链）。
    private static func hull(_ input: [CGPoint]) -> [CGPoint] {
        let pts = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// 沿一条折线两边各让出 half 宽的带子（眉毛用；两头收成圆的）。
    private static func band(_ line: [CGPoint], half: CGFloat) -> [CGPoint] {
        // Vision 的眉毛点有时是一圈轮廓：按 x 排好当成一条线。
        let pts = line.sorted { $0.x < $1.x }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in pts.indices {
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1e-6)
            let n = CGPoint(x: -dy / len * half, y: dx / len * half)
            left.append(CGPoint(x: pts[i].x + n.x, y: pts[i].y + n.y))
            right.append(CGPoint(x: pts[i].x - n.x, y: pts[i].y - n.y))
        }
        // 两头各补半圈：从这一侧绕过线头转到另一侧。
        func cap(_ c: CGPoint, from: CGFloat) -> [CGPoint] {
            (1..<6).map { i in
                let a = from - CGFloat(i) / 6 * .pi
                return CGPoint(x: c.x + cos(a) * half, y: c.y + sin(a) * half)
            }
        }
        let endDir = atan2(pts[pts.count - 1].y - pts[max(0, pts.count - 2)].y, pts[pts.count - 1].x - pts[max(0, pts.count - 2)].x)
        let startDir = atan2(pts[min(1, pts.count - 1)].y - pts[0].y, pts[min(1, pts.count - 1)].x - pts[0].x)
        return left + cap(pts[pts.count - 1], from: endDir + .pi / 2) + right.reversed() + cap(pts[0], from: startDir - .pi / 2)
    }
}
