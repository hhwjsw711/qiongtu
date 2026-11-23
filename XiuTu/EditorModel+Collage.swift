import CoreImage
import ImageIO
import PhotosUI
import SwiftUI

/// 拼图工具打开期间的全部状态。
struct CollageState {
    var params = CollageParams()
    /// 选中的是第几张图（模板里也就是第几格）。
    var selected: Int?
    /// 模板列表按哪个比例筛选；nil = 全部。
    var ratioFilter: CollageRatio?
    /// 相册选择器是否打开。
    var pickerShown = false
    /// 不为空 = 选回来的图替换第几张；为空 = 加在后面。
    var pickerReplace: Int?
    /// 这一次最多能选几张。
    var pickerLimit = 8
    /// 正在读取选回来的图。
    var loading = false
    /// 面板底下的一句提示。
    var note: String?
    /// 长按拖动换位置：从哪一格拖到哪一格。
    var swapFrom: Int?
    var swapTo: Int?
}

/// 拼接时可以推的边。
enum StitchEdge: Hashable {
    case start
    case seam(Int)
    case end
}

/// 模板列表里的一项：模板 + 用哪个画布比例。
struct CollageChoice: Identifiable {
    let layout: CollageLayout
    let ratio: CollageRatio
    var id: String { layout.id + "@" + ratio.rawValue }
}

/// 把相册里选回来的图读成拼图用的位图。
enum CollageImport {
    /// 摆正方向，长边缩到 3072 以内；另外备一张小图给实时预览用。
    ///
    /// 大图不以解开的位图留在内存里（一张就要二三十 MB，拼接又可以一直加图），
    /// 而是重新压成 JPEG、用的时候再解码：每张只占一两 MB。实时预览只用小图，不会反复解码。
    static func picture(from data: Data) -> CollagePicture? {
        guard let full = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let scaled = Renderer.shared.downscaled(full, maxDimension: 3072)
        // 带透明的图（PNG）先垫上白底，不然压成 JPEG 后透明的地方会变黑。
        let flat = scaled.composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: scaled.extent))
        guard let small = Renderer.shared.rasterize(flat, maxDimension: 1100) else { return nil }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        if let jpeg = Renderer.shared.context.jpegRepresentation(of: flat, colorSpace: Renderer.displaySpace,
                                                                 options: [quality: 0.95]),
           let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let lazy = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
            return CollagePicture(image: lazy, small: small.cg)
        }
        // 压不成就退回普通位图。
        guard let big = Renderer.shared.rasterize(flat, maxDimension: 3072) else { return nil }
        return CollagePicture(image: big.cg, small: small.cg)
    }
}

/// EditorModel 在这些时机调用下面的函数（工具是 .collage 时）。
extension EditorModel {
    func beginCollage() {
        collageState = CollageState()
        renderCollage()
    }

    /// 点 ✓ 时要写进历史的那一步；没加别的图返回 nil。
    func collageOp() -> EditOp? {
        let params = collageState.params
        return params.isIdentity ? nil : .collage(params)
    }

    /// 正在编辑的图的尺寸（预览图的），排版时当作"第一张图"的尺寸。
    var collageReference: CGSize {
        basePreview?.extent.size ?? CGSize(width: 3, height: 4)
    }

    /// 按当前参数重新拼一遍，显示到画布上。
    func renderCollage() {
        guard let base = basePreview else { return }
        showLive(collageState.params.render(base: base, preview: true))
    }

    // MARK: 拼接裁剪

    /// 拼接时推一条边。start = 第一张图的开头，seam(i) = 第 i 张和下一张之间的接缝，end = 最后一张的结尾。
    /// moved 是从按下到现在沿拼接方向挪了多少（以图的宽 / 高为 1；竖拼向下、横拼向右为正），from 是按下时的图。
    func collageStitchPush(_ edge: StitchEdge, moved: CGFloat, from start: [CollagePicture]) {
        var pics = start
        let full = collageState.params.stitchFullLengths(reference: collageReference)
        guard pics.count == full.count, !pics.isEmpty else { return }
        func clampStart(_ i: Int, _ v: CGFloat) { pics[i].cropStart = min(max(v, 0), 0.95 - pics[i].cropEnd) }
        func clampEnd(_ i: Int, _ v: CGFloat) { pics[i].cropEnd = min(max(v, 0), 0.95 - pics[i].cropStart) }
        switch edge {
        case .start:
            clampStart(0, start[0].cropStart + moved / full[0])
        case .end:
            let i = pics.count - 1
            clampEnd(i, start[i].cropEnd - moved / full[i])
        case .seam(let i):
            guard i + 1 < pics.count else { return }
            let up = i, down = i + 1
            if moved > 0 {
                // 往下推：先把上面那张裁掉的放回来，放完了再裁下面那张的开头。
                let giveBack = min(moved, start[up].cropEnd * full[up])
                clampEnd(up, start[up].cropEnd - giveBack / full[up])
                clampStart(down, start[down].cropStart + (moved - giveBack) / full[down])
            } else {
                let m = -moved
                let giveBack = min(m, start[down].cropStart * full[down])
                clampStart(down, start[down].cropStart - giveBack / full[down])
                clampEnd(up, start[up].cropEnd + (m - giveBack) / full[up])
            }
        }
        collageState.params.pictures = pics
        renderCollage()
    }

    // MARK: 模板

    /// 面板里要列出来的模板。"全部"时每个模板按自己最合适的比例；选了比例就只列放得下的。
    var collageChoices: [CollageChoice] {
        if let ratio = collageState.ratioFilter {
            return CollageLayout.all.filter { $0.fits(ratio) }.map { CollageChoice(layout: $0, ratio: ratio) }
        }
        return CollageLayout.all.map { CollageChoice(layout: $0, ratio: $0.natural) }
    }

    func collageSetMode(_ mode: CollageParams.Mode) {
        guard collageState.params.mode != mode else { return }
        collageState.params.mode = mode
        collageState.selected = nil
        collageState.swapFrom = nil
        collageState.swapTo = nil
        if mode == .template { collageFitLayout() }
        collageRefreshNote()
        renderCollage()
    }

    func collageSetRatioFilter(_ ratio: CollageRatio?) {
        collageState.ratioFilter = ratio
        guard let ratio else { return }
        collageState.params.ratio = ratio
        if !collageState.params.layout.fits(ratio) {
            collageState.params.layout = collageBestLayout(count: collageState.params.pictures.count, ratio: ratio)
        }
        collageRefreshNote()
        renderCollage()
    }

    func collageSelect(_ layout: CollageLayout, ratio: CollageRatio) {
        collageState.params.layout = layout
        collageState.params.ratio = ratio
        if let i = collageState.selected, i >= layout.cells.count { collageState.selected = nil }
        collageRefreshNote()
        renderCollage()
    }

    /// 这个比例下，格子数够放 count 张图的第一个模板；都不够就用格子最多的。
    private func collageBestLayout(count: Int, ratio: CollageRatio) -> CollageLayout {
        let usable = CollageLayout.all.filter { $0.fits(ratio) }
        return usable.first { $0.cells.count >= max(count, 2) } ?? usable.last ?? CollageLayout.all[0]
    }

    /// 图比格子多的时候，自动换成格子够用的模板。
    private func collageFitLayout() {
        let params = collageState.params
        guard params.pictures.count > params.layout.cells.count else { return }
        collageState.params.layout = collageBestLayout(count: params.pictures.count, ratio: params.ratio)
    }

    private func collageRefreshNote() {
        let hidden = collageState.params.hiddenCount
        collageState.note = hidden > 0 ? "这个模板放不下全部的图，还有 \(hidden) 张没显示。换个格子更多的模板，或者用\u{201C}拼接\u{201D}。" : nil
    }

    // MARK: 加图 / 换图

    /// 点了画布：点的是图就选中（再点一下取消），点的是空格子就去相册加图。
    func collageTap(_ index: Int) {
        if index < collageState.params.pictures.count {
            collageState.selected = collageState.selected == index ? nil : index
        } else {
            collageRequestAdd()
        }
    }

    func collageRequestAdd() {
        let params = collageState.params
        collageState.pickerReplace = nil
        if params.mode == .template {
            let room = CollageLayout.maxCells - params.pictures.count
            guard room > 0 else {
                collageState.note = "模板最多放 \(CollageLayout.maxCells) 张图。想接更多张，用\u{201C}拼接\u{201D}。"
                return
            }
            collageState.pickerLimit = room
        } else {
            collageState.pickerLimit = 20
        }
        collageState.pickerShown = true
    }

    func collageRequestReplace(_ index: Int) {
        guard collageState.params.pictures.indices.contains(index) else { return }
        collageState.pickerReplace = index
        collageState.pickerLimit = 1
        collageState.pickerShown = true
    }

    /// 相册里选好了：读出来，放进拼图。
    func collageImport(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let replace = collageState.pickerReplace
        collageState.loading = true
        collageState.note = nil
        Task { [weak self] in
            var loaded: [CollagePicture] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let picture = await Task.detached(priority: .userInitiated) { CollageImport.picture(from: data) }.value
                if let picture { loaded.append(picture) }
            }
            guard let self, self.tool == .collage else { return }
            self.collageState.loading = false
            guard !loaded.isEmpty else {
                self.collageState.note = "这张图读不出来，换一张试试。"
                return
            }
            if let index = replace, self.collageState.params.pictures.indices.contains(index) {
                self.collageState.params.pictures[index] = loaded[0]
            } else {
                self.collageState.params.pictures.append(contentsOf: loaded)
                if self.collageState.params.mode == .template { self.collageFitLayout() }
            }
            self.collageRefreshNote()
            if loaded.count < items.count {
                self.collageState.note = "有 \(items.count - loaded.count) 张图读不出来，已跳过。"
            }
            self.renderCollage()
        }
    }

    // MARK: 调整某一张

    func collageRemove(_ index: Int) {
        guard collageState.params.pictures.indices.contains(index) else { return }
        collageState.params.pictures.remove(at: index)
        collageState.selected = nil
        collageRefreshNote()
        renderCollage()
    }

    /// 往前（-1）或往后（+1）挪一位。
    func collageMove(_ index: Int, by step: Int) {
        let target = index + step
        guard collageState.params.pictures.indices.contains(index),
              collageState.params.pictures.indices.contains(target) else { return }
        collageState.params.pictures.swapAt(index, target)
        collageState.selected = target
        renderCollage()
    }

    func collageSwap(_ a: Int, _ b: Int) {
        guard a != b, collageState.params.pictures.indices.contains(a),
              collageState.params.pictures.indices.contains(b) else { return }
        collageState.params.pictures.swapAt(a, b)
        collageState.selected = b
        renderCollage()
    }

    func collageFlip(_ index: Int) {
        guard collageState.params.pictures.indices.contains(index) else { return }
        collageState.params.pictures[index].flip.toggle()
        renderCollage()
    }

    func collageRotate(_ index: Int) {
        guard collageState.params.pictures.indices.contains(index) else { return }
        collageState.params.pictures[index].quarterTurns = (collageState.params.pictures[index].quarterTurns + 1) % 4
        renderCollage()
    }

    /// 把图在格子里的位置和放大倍数还原成"居中铺满"。
    func collageResetFit(_ index: Int) {
        guard collageState.params.pictures.indices.contains(index) else { return }
        collageState.params.pictures[index].offset = .zero
        collageState.params.pictures[index].zoom = 1
        renderCollage()
    }

    func collagePan(_ index: Int, to offset: CGPoint) {
        guard collageState.params.pictures.indices.contains(index) else { return }
        collageState.params.pictures[index].offset = CGPoint(x: min(max(offset.x, -1), 1), y: min(max(offset.y, -1), 1))
        renderCollage()
    }

    func collageZoom(_ index: Int, to zoom: CGFloat) {
        guard collageState.params.pictures.indices.contains(index) else { return }
        collageState.params.pictures[index].zoom = min(max(zoom, 1), 4)
        renderCollage()
    }

    // MARK: 拼接

    /// 自动拼图打开时：切到竖拼，第一张是正在编辑的这张，后面几张从文件读，按算好的位置裁好两头。
    func collageLoadAutoStitch(_ job: AutoStitchJob) {
        guard tool == .collage, job.files.count == job.cropStart.count, job.files.count == job.cropEnd.count else { return }
        collageSetMode(.stitch)
        collageState.params.vertical = true
        collageState.params.stitchGap = 0
        collageState.loading = true
        Task { [weak self] in
            let rest = Array(job.files.dropFirst())
            let loaded = await Task.detached(priority: .userInitiated) {
                rest.map { url in (try? Data(contentsOf: url)).flatMap { CollageImport.picture(from: $0) } }
            }.value
            guard let self, self.tool == .collage else { return }
            self.collageState.loading = false
            var pics = [CollagePicture(isBase: true)]
            var starts = [job.cropStart[0]], ends = [job.cropEnd[0]]
            for (k, picture) in loaded.enumerated() {
                guard let picture else { continue }
                pics.append(picture)
                starts.append(job.cropStart[k + 1])
                ends.append(job.cropEnd[k + 1])
            }
            for i in pics.indices {
                pics[i].cropStart = min(max(starts[i], 0), 0.95)
                pics[i].cropEnd = min(max(ends[i], 0), 0.95 - pics[i].cropStart)
            }
            self.collageState.params.pictures = pics
            self.renderCollage()
            for url in job.files { try? FileManager.default.removeItem(at: url) }
        }
    }

    func collageSetVertical(_ vertical: Bool) {
        guard collageState.params.vertical != vertical else { return }
        collageState.params.vertical = vertical
        renderCollage()
    }
}
