import CoreImage
import SwiftUI
import UIKit

/// 图层工具打开期间的全部状态。
///
/// 图层在编辑历史里是一步（EditOp.layers）。它前面的步骤属于"图层下面的照片"，
/// 后面的步骤（之后做的滤镜、调色……）作用在合并后的整张图上。
/// 再次打开图层工具时，是把历史里的这一步拿出来原地修改，前后的步骤都保留。
struct LayerState {
    /// 从下到上。
    var layers: [ImageLayer] = []
    /// nil = 选中的是下面的照片。
    var selectedID: UUID?
    /// 正在导入、抠图或重新生成图层内容。
    var busy = false
    var note: String?
    /// 正在 AI 融合。
    var fusing = false
    var fuseStarted = Date()
    /// 图层下面那张照片的修改步骤。
    var prefix: [EditOp] = []
    /// 图层之后的步骤。
    var suffix: [EditOp] = []
    var changed = false
    /// 图层下面的照片（预览大小），以及它的小图。
    var background: CIImage?
    var backgroundThumb: UIImage?
    /// 给新图层起名用。
    var counter = 0
}

extension EditorModel {
    var selectedLayer: ImageLayer? {
        guard let id = layerState.selectedID else { return nil }
        return layerState.layers.first { $0.id == id }
    }

    // MARK: 进出

    func beginLayers() {
        var state = LayerState()
        let index = ops.lastIndex { op in
            if case .layers = op { return true }
            return false
        }
        if let index, case .layers(let stack) = ops[index] {
            state.layers = stack.layers
            state.prefix = Array(ops[..<index])
            state.suffix = Array(ops[(index + 1)...])
            state.selectedID = stack.layers.last?.id
        } else {
            state.prefix = ops
            state.background = basePreview
            state.backgroundThumb = baseUIImage
        }
        state.counter = state.layers.count
        layerState = state
        if state.background == nil { rebuildLayerBackground() }
    }

    /// 点 ✓：把图层这一步写回历史里原来的位置。
    func commitLayers(then next: (() -> Void)?) {
        let state = layerState
        guard !state.busy else { return }
        guard state.changed else {
            cancelTool()
            next?()
            return
        }
        var newOps = state.prefix
        if !state.layers.isEmpty { newOps.append(.layers(LayerStack(layers: state.layers))) }
        newOps.append(contentsOf: state.suffix)
        replaceOps(newOps, then: next)
    }

    // MARK: AI 融合

    /// 融合用的指令。按每一层是什么（抠好的主体还是整张照片）、底下的照片里有没有人来拼。
    static func fusePrompt(layers: [ImageLayer], baseHasPerson: Bool) -> String {
        var lines = [
            "第 1 张图是把几张照片叠在一起的粗合成，位置只是大概摆的。请参考后面附的原图，把它们重新合成为一张真实、自然、像一次拍下来的照片。",
            "第 2 张图是最底下的原照片。",
        ]
        if baseHasPerson {
            lines.append("【最重要】原照片里的人物是这张照片的主角：人物在画面里的位置、大小、轮廓、姿势和手的位置都和第 2 张原照片完全一样，一个像素都不要挪，也不要重画人物；长相、脸型、胖瘦、发型和服装都不变。人物只有一个，不要出现重影或多出来的手。粗合成里如果有图层挡住了人，那是摆放的问题，不要照着挡。")
        }
        for (i, layer) in layers.enumerated() {
            let n = i + 3
            if layer.cutout {
                lines.append("第 \(n) 张图是抠好的主体（人或物体），要放进画面里、大致在粗合成里的位置，形状和细节不变。")
            } else if baseHasPerson {
                lines.append("第 \(n) 张图是一张完整的场景照片：把它当成新的背景和环境，放在人物身后，让人物看起来就站在这个地方，人物脚下的地面和周围环境要和这个场景连贯。")
            } else {
                lines.append("第 \(n) 张图是一张照片，按粗合成里的位置和大小把它的内容自然地融进画面。")
            }
        }
        lines.append(baseHasPerson
            ? "【构图】人物不动，只通过调整背景场景的位置、远近和大小来构图：场景里的地标（建筑、塔、山、月亮等）要完整、好看地出现在人物身后，不要被画面边缘切掉顶部，上方留出适当的天空，画面平衡。"
            : "【构图】像一位专业摄影师在现场重新取景：主体和场景里的地标都要完整、好看地放在画面里，地标不要被画面边缘切掉顶部，上方留出适当的天空，画面平衡，主体可以偏在一侧，不要放在死板的正中间；画面里不要画出网格、辅助线或取景框。")
        lines.append("统一所有元素的光线方向和强弱、色温色调、反差、景深虚实、清晰度和画质；给人和物体补上符合场景的阴影、反光和与地面的接触；修掉抠图的硬边、白边和残留背景，发丝边缘自然；按场景的透视让大小比例合理。画面比例和第 1 张一致。")
        lines.append("附的原图只用来参考和保持细节，不要把它们原样拼贴进画面，也不要出现拼贴的边框。结果必须是一张真实的相机照片：清晰度和原照片一致，不要过度锐化、不要边缘白边、不要塑料感的皮肤和过高的饱和度，不要有 AI 生成感和插画感。")
        return lines.joined(separator: "\n")
    }

    /// AI 融合：把下面的照片和所有图层交给 AI，融成一张自然的照片。完成后图层这一步和融合结果都写进历史，可以撤销。
    func fuseLayers() {
        guard tool == .layers, !layerState.busy, !layerState.layers.isEmpty, let proxy else { return }
        guard let endpoint = AISettings.shared.endpoint() else {
            layerState.note = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        let state = layerState
        let stack = LayerStack(layers: state.layers)
        let visible = Array(state.layers.filter { !$0.hidden }.suffix(3))
        let baseImage = state.backgroundThumb
        layerState.busy = true
        layerState.fusing = true
        layerState.fuseStarted = Date()
        layerState.note = nil
        Task { [weak self] in
            do {
                // 底下的照片里有没有人：有人就以人为主角，整张照片的图层当背景。
                let personMask = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let cg = baseImage?.cgImage else { return nil }
                    return PersonSegmenter.mask(for: cg)
                }.value
                let hasPerson: Bool
                if personMask != nil {
                    hasPerson = true
                } else {
                    hasPerson = await Task.detached(priority: .userInitiated) { () -> Bool in
                        guard let cg = baseImage?.cgImage else { return false }
                        return !FaceDetector.detect(in: cg).isEmpty
                    }.value
                }
                let references = (baseImage.map { [$0] } ?? []) + visible.map { UIImage(cgImage: $0.content) }
                _ = AIClient.takeLastUsage()
                let result = try await AIRunner.run(endpoint: endpoint, prompt: Self.fusePrompt(layers: visible, baseHasPerson: hasPerson),
                                                    proxy: proxy, ops: state.prefix + [.layers(stack)], strokes: [], crop: nil,
                                                    appendGuidance: false, references: references)
                _ = AIClient.takeLastUsage()
                // 有人、而且图层都是整张的场景（没有要放在人前面的抠图）：把原照片里的人原样贴回去，
                // 只借 AI 结果的光影和颜色，这样脸、胖瘦和手都是原图的，不会变也不会有重影。
                var final = result
                if let personMask, !visible.contains(where: { $0.cutout }) {
                    final = await Task.detached(priority: .userInitiated) { () -> CGImage in
                        Self.restorePerson(fused: result, base: EditOp.apply(state.prefix, to: proxy), mask: personMask) ?? result
                    }.value
                }
                guard let self, self.tool == .layers else { return }
                self.layerState.busy = false
                self.layerState.fusing = false
                // 历史：下面的照片 → 图层 → 融合结果 → 之后的步骤。
                let fused = AIEdit(result: final, strokes: [])
                if state.suffix.isEmpty {
                    // 先把图层这一步存下，再把融合结果放进结果面板，调好柔化再确认。
                    self.replaceOps(state.prefix + [.layers(stack)]) { [weak self] in self?.showFusedResult(final) }
                } else {
                    var soft = fused
                    soft.soften = 0
                    self.replaceOps(state.prefix + [.layers(stack), .ai(soft)] + state.suffix)
                }
            } catch {
                guard let self, self.tool == .layers else { return }
                self.layerState.busy = false
                self.layerState.fusing = false
                if !(error is CancellationError) { self.layerState.note = error.localizedDescription }
            }
        }
    }

    /// 把原照片里的人贴回融合结果：人物的细节用原图，整体的光影颜色跟着融合结果走。
    /// 蒙版往里收一点再羽化，边上用的是 AI 那一圈像素，原图的背景（比如绿树）不会被带出来，就没有色边。
    /// AI 的背景往往锐化过头，轻轻柔一下，和原图人物的清晰度对上。
    nonisolated static func restorePerson(fused: CGImage, base: CIImage, mask: CGImage) -> CGImage? {
        let b = base.transformed(by: CGAffineTransform(translationX: -base.extent.minX, y: -base.extent.minY))
        let extent = b.extent
        // 不超过 4096，免得太占内存。
        let k = min(1, 4096 / max(extent.width, extent.height))
        let target = CGRect(x: 0, y: 0, width: (extent.width * k).rounded(), height: (extent.height * k).rounded())
        let dim = max(target.width, target.height)
        let original = b.transformed(by: CGAffineTransform(scaleX: target.width / extent.width, y: target.height / extent.height))
            .cropped(to: target)
        var ai = CIImage(cgImage: fused)
        ai = ai.transformed(by: CGAffineTransform(scaleX: target.width / ai.extent.width, y: target.height / ai.extent.height))
            .cropped(to: target)
        // 背景去掉过度锐化：和轻微模糊的自己对半混。
        let soft = ai.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: dim * 0.0007])
            .cropped(to: target)
        ai = FX.mix(ai, soft, t: 0.55)
        // 人物：用大半径取光影，只跟着整体的明暗冷暖走，不会出现一块块的色斑。
        let person = ToneTransfer.apply(original: original, graded: ai, radius: dim * 0.06)
        let m = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: target.width / CGFloat(mask.width), y: target.height / CGFloat(mask.height)))
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: dim * 0.0025])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: dim * 0.0025])
            .cropped(to: target)
        let out = person.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: ai,
            kCIInputMaskImageKey: m,
        ]).cropped(to: target)
        return Renderer.shared.cgImage(out)
    }

    /// 重新算一遍"图层下面的照片"的预览。
    private func rebuildLayerBackground() {
        guard let proxy else { return }
        let prefix = layerState.prefix
        layerState.busy = true
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (CIImage, UIImage)? in
                let out = EditOp.apply(prefix, to: proxy)
                guard let r = Renderer.shared.rasterize(out, maxDimension: 1600) else { return nil }
                return (r.ci, UIImage(cgImage: r.cg))
            }.value
            guard let self, self.tool == .layers else { return }
            self.layerState.busy = false
            if let result {
                self.layerState.background = result.0
                self.layerState.backgroundThumb = result.1
            }
            self.renderLayers()
        }
    }

    /// 实时预览：下面的照片 + 各个图层的小图。
    func renderLayers() {
        guard tool == .layers, let background = layerState.background else { return }
        showLive(LayerStack(layers: layerState.layers).composite(over: background, usePreview: true))
    }

    // MARK: 增删改

    /// 从相册选的一张图，加成新图层。
    func addLayer(data: Data) {
        guard tool == .layers, !layerState.busy else { return }
        layerState.busy = true
        layerState.note = nil
        let number = layerState.counter + 1
        let canvas = layerState.background?.extent.size ?? CGSize(width: 1, height: 1)
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> ImageLayer? in
                guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
                return ImageLayer.make(name: "图层 \(number)", image: image)
            }.value
            guard let self, self.tool == .layers else { return }
            self.layerState.busy = false
            guard var layer = made else {
                self.layerState.note = "这张图片读不出来。"
                return
            }
            layer.width = Self.fittingWidth(aspect: layer.aspect, canvas: canvas, fill: 0.7)
            self.layerState.counter = number
            self.layerState.layers.append(layer)
            self.layerState.selectedID = layer.id
            self.layerState.changed = true
            self.renderLayers()
        }
    }

    /// 新建一个透明的空白图层：和画面一样的比例，铺满整个画面，之后可以在上面画、加东西。
    func addBlankLayer() {
        guard tool == .layers, !layerState.busy else { return }
        let canvas = layerState.background?.extent.size ?? CGSize(width: 1, height: 1)
        guard canvas.width > 0, canvas.height > 0 else { return }
        let k = min(1, 2048 / max(canvas.width, canvas.height))
        let size = CGRect(x: 0, y: 0, width: max((canvas.width * k).rounded(), 1), height: max((canvas.height * k).rounded(), 1))
        let number = layerState.counter + 1
        guard var layer = ImageLayer.make(name: "图层 \(number)", image: CIImage(color: .clear).cropped(to: size)) else { return }
        layer.width = 1
        layer.center = CGPoint(x: 0.5, y: 0.5)
        layerState.note = nil
        layerState.counter = number
        layerState.layers.append(layer)
        layerState.selectedID = layer.id
        layerState.changed = true
        renderLayers()
    }

    /// 让图层整个落在画面里时的宽度比例。fill = 最多占画面的多少。
    private static func fittingWidth(aspect: CGFloat, canvas: CGSize, fill: CGFloat) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0, aspect > 0 else { return fill }
        // 图层高度 = width * canvas.width * aspect，不能超过 fill * canvas.height。
        return min(fill, fill * canvas.height / (canvas.width * aspect))
    }

    func updateLayer(_ id: UUID, _ change: (inout ImageLayer) -> Void) {
        guard let i = layerState.layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layerState.layers[i])
        layerState.changed = true
        renderLayers()
    }

    func removeLayer(_ id: UUID) {
        guard let i = layerState.layers.firstIndex(where: { $0.id == id }) else { return }
        layerState.layers.remove(at: i)
        if layerState.selectedID == id {
            layerState.selectedID = layerState.layers.indices.contains(i - 1) ? layerState.layers[i - 1].id
                : layerState.layers.first?.id
        }
        layerState.changed = true
        renderLayers()
    }

    func duplicateLayer(_ id: UUID) {
        guard let i = layerState.layers.firstIndex(where: { $0.id == id }) else { return }
        var copy = layerState.layers[i]
        copy.id = UUID()
        layerState.counter += 1
        copy.name = "图层 \(layerState.counter)"
        copy.center = CGPoint(x: min(copy.center.x + 0.05, 1), y: min(copy.center.y + 0.05, 1))
        layerState.layers.insert(copy, at: i + 1)
        layerState.selectedID = copy.id
        layerState.changed = true
        renderLayers()
    }

    /// 往上（delta = 1）或往下（delta = -1）挪一层。
    func moveLayer(_ id: UUID, by delta: Int) {
        guard let i = layerState.layers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard layerState.layers.indices.contains(j) else { return }
        layerState.layers.swapAt(i, j)
        layerState.changed = true
        renderLayers()
    }

    /// 摆回正中间，大小正好铺进画面。
    func fitLayer(_ id: UUID) {
        let canvas = layerState.background?.extent.size ?? CGSize(width: 1, height: 1)
        updateLayer(id) { layer in
            layer.center = CGPoint(x: 0.5, y: 0.5)
            layer.rotation = 0
            layer.width = Self.fittingWidth(aspect: layer.aspect, canvas: canvas, fill: 1)
        }
    }

    // MARK: 抠图 / 单独编辑

    /// 开关"去背景"。第一次打开时在本机识别一次主体。
    func setLayerCutout(_ id: UUID, _ on: Bool) {
        rebuildLayer(id, editedChanged: false, failure: "本机没有识别到主体，可以用 AI 去背景。") { $0.cutout = on }
    }

    /// AI 去背景：让 AI 把背景换成绿幕，本机再按绿幕算出蒙版，贴上去的仍然是原图的像素。计一次费。
    func aiCutoutLayer(_ id: UUID) {
        guard tool == .layers, !layerState.busy,
              let layer = layerState.layers.first(where: { $0.id == id }) else { return }
        guard let endpoint = AISettings.shared.endpoint() else {
            layerState.note = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        layerState.busy = true
        layerState.note = nil
        Task { [weak self] in
            var made: ImageLayer?
            var failure: String?
            do {
                _ = AIClient.takeLastUsage()
                let keyed = try await AIRunner.run(endpoint: endpoint, prompt: Cutout.aiPrompt,
                                                   proxy: CIImage(cgImage: layer.edited), ops: [], strokes: [],
                                                   crop: nil, appendGuidance: false)
                if let cost = AIClient.takeLastUsage()?.cost { AISettings.shared.addSpend(cost) }
                made = await Task.detached(priority: .userInitiated) { () -> ImageLayer? in
                    guard let mask = Cutout.mask(fromKeyed: keyed) else { return nil }
                    var l = layer
                    l.mask = mask
                    l.cutout = true
                    return l.rebuild(editedChanged: false) ? l : nil
                }.value
                if made == nil { failure = "AI 没有把背景分出来，可以再试一次。" }
            } catch {
                failure = error.localizedDescription
            }
            guard let self, self.tool == .layers else { return }
            self.layerState.busy = false
            self.layerState.note = failure
            guard let made, let j = self.layerState.layers.firstIndex(where: { $0.id == id }) else { return }
            var merged = self.layerState.layers[j]
            merged.mask = made.mask
            merged.cutout = made.cutout
            merged.content = made.content
            merged.preview = made.preview
            self.layerState.layers[j] = merged
            self.layerState.changed = true
            self.renderLayers()
        }
    }

    func setLayerFeather(_ id: UUID, _ value: CGFloat) {
        rebuildLayer(id, editedChanged: false, failure: nil) { $0.feather = min(max(value, 0), 1) }
    }

    /// 单独编辑完这个图层的内容，把新的修改步骤交回来。
    func applyLayerEdit(_ id: UUID, ops: [EditOp]) {
        rebuildLayer(id, editedChanged: true, failure: "改完以后本机没有识别到主体，去背景已关掉。") { $0.ops = ops }
    }

    private func rebuildLayer(_ id: UUID, editedChanged: Bool, failure: String?, _ change: (inout ImageLayer) -> Void) {
        guard tool == .layers, !layerState.busy,
              let i = layerState.layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = layerState.layers[i]
        let wanted = layer.cutout
        change(&layer)
        let wantsCutout = layer.cutout || wanted
        layerState.busy = true
        layerState.note = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (ImageLayer, Bool) in
                var l = layer
                let ok = l.rebuild(editedChanged: editedChanged)
                return (l, ok)
            }.value
            guard let self, self.tool == .layers else { return }
            self.layerState.busy = false
            if let j = self.layerState.layers.firstIndex(where: { $0.id == id }) {
                // 摆放可能在等的这会儿被改过，只换图不换位置。
                var merged = self.layerState.layers[j]
                merged.ops = result.0.ops
                merged.edited = result.0.edited
                merged.mask = result.0.mask
                merged.cutout = result.0.cutout
                merged.feather = result.0.feather
                merged.content = result.0.content
                merged.preview = result.0.preview
                self.layerState.layers[j] = merged
            }
            if !result.1, wantsCutout { self.layerState.note = failure }
            self.layerState.changed = true
            self.renderLayers()
        }
    }

    /// 单独编辑一个图层的内容。
    func layerEditRequest(for id: UUID) -> LayerEditRequest? {
        guard let layer = layerState.layers.first(where: { $0.id == id }) else { return nil }
        return LayerEditRequest(title: layer.name, source: CIImage(cgImage: layer.original), ops: layer.ops) { [weak self] ops in
            self?.applyLayerEdit(id, ops: ops)
        }
    }

    /// 单独编辑图层下面的那张照片。
    func backgroundEditRequest() -> LayerEditRequest? {
        guard let source else { return nil }
        return LayerEditRequest(title: "照片", source: source, ops: layerState.prefix) { [weak self] ops in
            guard let self, self.tool == .layers else { return }
            self.layerState.prefix = ops
            self.layerState.changed = true
            self.rebuildLayerBackground()
        }
    }
}
