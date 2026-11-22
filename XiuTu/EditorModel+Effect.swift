import CoreImage
import SwiftUI
import UIKit

/// 特效工具打开期间的全部状态。
struct EffectState {
    enum MaskStatus { case idle, working, ready, missing }

    var params = EffectParams()
    var category: EffectCategory = .light
    /// 每个效果套在当前照片小图上的样子（EffectKind.id → 图）。
    var thumbs: [String: UIImage] = [:]
    var original: UIImage?
    var mask: CGImage?
    var maskStatus: MaskStatus = .idle
    var error: String?
    /// 这次打开工具的编号，后台算完的东西对不上就丢掉。
    var token = UUID()
}

extension EditorModel {
    func beginEffect() {
        effectState = EffectState()
        guard let base = basePreview else { return }
        let token = effectState.token
        effectState.maskStatus = .working
        Task.detached(priority: .userInitiated) { [weak self] in
            // 先出不需要蒙版的缩略图。
            let small = Renderer.shared.rasterize(EditorModel.centerCrop(base, aspect: 68.0 / 84.0), maxDimension: 240)
            if let small {
                let original = UIImage(cgImage: small.cg)
                let thumbs = EditorModel.effectThumbs(small.ci, mask: nil, kinds: EffectKind.allCases.filter { !$0.needsMask })
                await self?.setEffectThumbs(thumbs, original: original, token: token)
            }
            // 再找主体。
            let mask = Renderer.shared.cgImage(base).flatMap { Cutout.mask(for: $0) }
            await self?.setEffectMask(mask, token: token)
            guard let mask, let small else { return }
            let cropped = EditorModel.centerCrop(Cutout.scaled(mask, to: base.extent), aspect: 68.0 / 84.0)
            let fitted = Renderer.shared.downscaled(cropped, maxDimension: 240)
            guard let thumbMask = Renderer.shared.context.createCGImage(
                fitted, from: fitted.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return }
            let thumbs = EditorModel.effectThumbs(small.ci, mask: thumbMask, kinds: EffectKind.allCases.filter(\.usesMask))
            await self?.setEffectThumbs(thumbs, original: nil, token: token)
        }
    }

    nonisolated private static func effectThumbs(_ image: CIImage, mask: CGImage?, kinds: [EffectKind]) -> [String: UIImage] {
        var out: [String: UIImage] = [:]
        for kind in kinds {
            let params = EffectParams(id: kind.id, strength: kind.defaultStrength, variant: 0, seed: 7, mask: mask)
            if let cg = Renderer.shared.cgImage(params.apply(to: image)) { out[kind.id] = UIImage(cgImage: cg) }
        }
        return out
    }

    private func setEffectThumbs(_ thumbs: [String: UIImage], original: UIImage?, token: UUID) {
        guard tool == .effect, effectState.token == token else { return }
        effectState.thumbs.merge(thumbs) { $1 }
        if let original { effectState.original = original }
    }

    private func setEffectMask(_ mask: CGImage?, token: UUID) {
        guard tool == .effect, effectState.token == token else { return }
        // 重新打开时已经带着蒙版了，这次没找到就沿用原来的。
        if mask == nil, effectState.mask != nil { return }
        effectState.mask = mask
        effectState.maskStatus = mask == nil ? .missing : .ready
        guard let kind = effectState.params.kind, kind.usesMask else { return }
        if let mask {
            effectState.params.mask = mask
            renderEffect()
        } else if kind.needsMask {
            // 先选了要蒙版的效果，结果没找到人。
            effectState.params = EffectParams()
            effectState.error = "没找到人物"
            renderEffect()
        }
    }

    /// 点 ✓ 时要写进历史的那一步；没改返回 nil。
    func effectOp() -> EditOp? {
        effectState.params.isIdentity ? nil : .effect(effectState.params)
    }

    func effectPendingOps() -> [EditOp]? {
        if let op = effectOp() { return [op] }
        return []
    }

    /// 选一个效果；nil = 不要特效。
    func selectEffect(_ kind: EffectKind?) {
        effectState.error = nil
        guard let kind else {
            effectState.params = EffectParams()
            renderEffect()
            return
        }
        if kind.needsMask, effectState.maskStatus == .missing {
            effectState.error = "没找到人物"
            return
        }
        var next = effectState.params
        if next.id != kind.id {
            next.id = kind.id
            next.strength = kind.defaultStrength
            next.variant = 0
            // 每次选一个随机排布的效果都重新随机一次，不会总是同一个样子。
            if kind.shuffles { next.seed = UInt64.random(in: 1...UInt64.max) }
        }
        next.mask = kind.usesMask ? effectState.mask : nil
        effectState.params = next
        renderEffect()
    }

    func setEffectStrength(_ value: CGFloat) {
        effectState.params.strength = min(max(value, 0), 1)
        renderEffect()
    }

    func setEffectVariant(_ index: Int) {
        effectState.params.variant = index
        renderEffect()
    }

    /// 随机的效果换一种排布。
    func shuffleEffect() {
        effectState.params.seed = UInt64.random(in: 1...UInt64.max)
        renderEffect()
    }

    /// 随机度 0.01...1。
    func setEffectChaos(_ value: CGFloat) {
        effectState.params.chaos = min(max(value, 0.01), 1)
        renderEffect()
    }

    private func renderEffect() {
        guard tool == .effect, let base = basePreview else { return }
        showLive(effectState.params.apply(to: base))
    }

    /// 把历史里已有的特效重新打开接着改（紧跟在 beginEffect 之后调用）。
    func reopenEffect(_ params: EffectParams) {
        effectState.params = params
        if let kind = params.kind { effectState.category = kind.category }
        if let mask = params.mask {
            effectState.mask = mask
            effectState.maskStatus = .ready
        }
        renderEffect()
    }
}
