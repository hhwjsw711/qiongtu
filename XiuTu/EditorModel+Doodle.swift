import CoreImage
import SwiftUI

/// 涂鸦 / 标记工具打开期间的全部状态。
struct DoodleState {
    /// 已经画完的笔画，按先后顺序。
    var strokes: [DoodleStroke] = []
    /// 撤销掉、还能重做的笔画。
    var redo: [DoodleStroke] = []
    var category: DoodleCategory = .pen
    var brush: DoodleBrush = .pen
    var erasing = false
    var color: DoodleColor = .white
    /// 笔在屏幕上的粗细（点）。画面放大以后，同样的数值画出来更细，方便描细节。
    var size: CGFloat = 8
    /// 浓度：整笔的不透明度。
    var opacity: CGFloat = 1
    /// 位图缓存。是引用类型，手指移动时改它不会让面板跟着刷新。
    var runtime: DoodleRuntime?
    /// 放大后渲染高清贴片用的那份笔画；笔画没变就一直是同一份，画好的那层可以复用。
    var pending = DoodleParams()
    /// 自动圆润：手指抬起后把这一笔修顺（画圈变圆、近似直线拉直）。
    var smooth = UserDefaults.standard.object(forKey: "doodle.smooth") as? Bool ?? true
    /// 图案笔的随机分布。
    var jitter = DoodleJitter()
    /// 面板上显示分布滑条（代替颜色那一行）。
    var showJitter = false
    /// 识别到的人脸（妆容笔用）；nil = 还在识别。
    var faces: [FaceInfo]?
    /// 出错时的一句话（比如没找到人脸）。
    var note: String?

    var canUndo: Bool { !strokes.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
}

/// EditorModel 在这些时机调用下面的函数（工具是 .doodle 或 .mark 时）。
extension EditorModel {
    /// 进入工具。
    func beginDoodle(_ tool: Tool) {
        var state = DoodleState()
        if tool == .mark {
            state.brush = .arrow
            state.color = .red
            state.size = 5
        }
        if let base = basePreview { state.runtime = DoodleRuntime(size: base.extent.size) }
        doodleState = state
        guard tool == .doodle, let base = basePreview else { return }
        // 妆容笔要知道五官在哪：进来就在后台找脸。
        Task { [weak self] in
            let faces = await Task.detached(priority: .userInitiated) { () -> [FaceInfo] in
                guard let cg = Renderer.shared.cgImage(base) else { return [] }
                return FaceDetector.detect(in: cg)
            }.value
            self?.doodleState.faces = faces
        }
    }

    /// 点 ✓ 时要写进历史的那一步；没画东西返回 nil。
    func doodleOp() -> EditOp? {
        // 直接用 pending 这一份：放大看细节时画好的那一层，确认以后还能接着用。
        let params = doodleState.pending
        return params.isIdentity ? nil : .doodle(params)
    }

    /// 还没确认的修改（放大后渲染高清贴片用）；返回 nil = 不显示高清贴片。
    func doodlePendingOps() -> [EditOp]? {
        // 正在画的时候不出高清贴片，手指抬起来再出。
        if doodleState.runtime?.active != nil { return nil }
        return doodleState.pending.isIdentity ? [] : [.doodle(doodleState.pending)]
    }

    /// 单指落下。point 是归一化图片坐标（原点左上角）；displayScale = 图片长边在屏幕上占多少点。
    func doodleStrokeBegan(at point: CGPoint, displayScale: CGFloat) {
        guard displayScale > 0, let runtime = doodleState.runtime else { return }
        let state = doodleState
        let brush: DoodleBrush = state.erasing ? .eraser : state.brush
        let width = min(max(state.size * brush.widthFactor / displayScale, 0.0004), 0.5)
        var stroke = DoodleStroke(brush: brush, points: [point], width: width, color: state.color,
                                  opacity: brush == .eraser ? 1 : state.opacity,
                                  seed: UInt64.random(in: 1...UInt64.max))
        if brush.category == .makeup {
            // 妆容笔只画在对应的五官上；没找到脸就不画。
            guard let faces = state.faces else {
                doodleState.note = "还在识别人脸"
                return
            }
            let region = DoodleFaceRegion.region(for: brush, faces: faces, size: runtime.size)
            guard !region.shapes.isEmpty else {
                doodleState.note = "没找到人脸"
                return
            }
            stroke.region = region.shapes
            stroke.feather = region.feather
        } else if brush.category == .pattern {
            stroke.jitter = state.jitter
        }
        if doodleState.note != nil { doodleState.note = nil }
        if brush == .number {
            stroke.number = state.strokes.filter { $0.brush == .number }.count + 1
        } else if brush.isShape {
            stroke.points = [point, point]
        }
        runtime.active = stroke
        doodleRender()
    }

    func doodleStrokeMoved(to point: CGPoint) {
        guard let runtime = doodleState.runtime, var stroke = runtime.active else { return }
        if stroke.brush == .number {
            stroke.points = [point]
        } else if stroke.brush.isShape {
            stroke.points[1] = point
        } else {
            if let last = stroke.points.last, hypot(last.x - point.x, last.y - point.y) < 0.0004 { return }
            stroke.points.append(point)
        }
        runtime.active = stroke
        doodleRender()
    }

    /// 手指抬起。
    func doodleStrokeEnded() {
        guard let runtime = doodleState.runtime, var stroke = runtime.active else { return }
        runtime.active = nil
        var keep = true
        if stroke.brush.isShape, stroke.brush != .number, stroke.points.count >= 2 {
            // 只是点了一下、没拖开的形状不留。
            let a = stroke.points[0], b = stroke.points[1]
            let long = max(runtime.size.width, runtime.size.height)
            let dragged = hypot((a.x - b.x) * runtime.size.width, (a.y - b.y) * runtime.size.height) / long
            keep = dragged > stroke.width * 0.8 + 0.004
        }
        // 还什么都没画的时候，橡皮擦的这一笔也不用记。
        if stroke.brush == .eraser, runtime.committedImage == nil { keep = false }
        if keep, doodleState.smooth, !stroke.brush.isShape, stroke.brush != .eraser {
            stroke.points = DoodleSmooth.process(stroke.points, size: runtime.size)
        }
        if keep {
            runtime.commit(stroke)
            var state = doodleState
            state.strokes.append(stroke)
            state.redo.removeAll()
            state.pending = DoodleParams(strokes: state.strokes)
            doodleState = state
        }
        doodleRender()
    }

    /// 撤销最后一笔（第二根手指落下、手势被取消时也会调用）。
    func doodleUndoStroke() {
        guard let runtime = doodleState.runtime else { return }
        if runtime.active != nil {
            // 这一笔还没画完（多半是第二根手指落下要缩放）：直接作废。
            runtime.active = nil
            doodleRender()
            return
        }
        guard doodleState.canUndo else { return }
        var state = doodleState
        state.redo.append(state.strokes.removeLast())
        state.pending = DoodleParams(strokes: state.strokes)
        doodleState = state
        runtime.rebuild(state.strokes)
        doodleRender()
    }

    func doodleRedoStroke() {
        guard let runtime = doodleState.runtime, runtime.active == nil, doodleState.canRedo else { return }
        var state = doodleState
        let stroke = state.redo.removeLast()
        state.strokes.append(stroke)
        state.pending = DoodleParams(strokes: state.strokes)
        doodleState = state
        runtime.commit(stroke)
        doodleRender()
    }

    /// 全部清掉。
    func doodleClear() {
        guard let runtime = doodleState.runtime, doodleState.canUndo else { return }
        runtime.active = nil
        var state = doodleState
        state.strokes.removeAll()
        state.redo.removeAll()
        state.pending = DoodleParams()
        doodleState = state
        runtime.rebuild([])
        doodleRender()
    }

    /// 换一支笔（或者标记里换一种形状）。浓度换成这支笔合适的默认值，妆容笔顺带换成对应的颜色。
    func selectDoodleBrush(_ brush: DoodleBrush) {
        var state = doodleState
        state.brush = brush
        state.erasing = false
        state.opacity = brush.defaultOpacity
        if let color = brush.defaultColor { state.color = color }
        if let category = brush.category { state.category = category }
        doodleState = state
    }

    func setDoodleSmooth(_ on: Bool) {
        doodleState.smooth = on
        UserDefaults.standard.set(on, forKey: "doodle.smooth")
    }

    private func doodleRender() {
        guard let base = basePreview, let runtime = doodleState.runtime else { return }
        var spots = doodleState.strokes.filter { $0.brush == .spot }
        if let active = runtime.active, active.brush == .spot { spots.append(active) }
        showLive(DoodleRenderer.compose(over: base, layers: runtime.layers(), spots: spots))
    }
}

extension EditorModel {
    /// 把历史里已有的涂鸦 / 标记重新打开接着画（紧跟在 beginDoodle 之后调用）。
    func reopenDoodle(_ params: DoodleParams) {
        var state = doodleState
        state.strokes = params.strokes
        state.redo = []
        state.pending = params
        state.runtime?.rebuild(params.strokes)
        doodleState = state
        doodleRender()
    }
}
