import CoreGraphics
import Foundation

/// 自动拼长图：几张连续滚动的截图（聊天记录、网页），去掉重复的部分接成一张。
/// 1. 每张图顶上的状态栏、标题栏和底下的输入框是固定不动的：找出来，只保留第一张的顶和最后一张的底。
/// 2. 中间的内容是滚动的：找出相邻两张之间滚了多少，后一张只接上新出现的那一截。
/// 全部在本机算，只用 Core Graphics。
enum AutoStitch {
    struct Result {
        let image: CGImage
        /// 有几处接缝没对上（直接整截接上去了）。
        let unmatched: Int
    }

    /// 每一行压成这么多个灰度值来比较。
    private static let columns = 48

    /// images 按时间先后排好；自动判断是往下滚还是往上滚。
    static func stitch(_ images: [CGImage]) -> Result? {
        guard images.count >= 2, let w = images.first?.width, let h = images.first?.height,
              images.allSatisfy({ $0.width == w && $0.height == h }) else { return nil }
        let sigs = images.compactMap { Signature($0) }
        guard sigs.count == images.count else { return nil }

        // 固定的头和尾：所有相邻两张都一样的那几行。
        var header = h, footer = h
        for i in 1..<sigs.count {
            let (top, bottom) = fixedBands(sigs[i - 1], sigs[i])
            header = min(header, top)
            footer = min(footer, bottom)
        }
        if header + footer > h * 7 / 10 { header = 0; footer = 0 }

        // 方向：第一对正着接和反着接哪个对得更好。
        let forward = overlap(sigs[0], sigs[1], header: header, footer: footer)
        let backward = overlap(sigs[1], sigs[0], header: header, footer: footer)
        var order = Array(images.indices)
        if let b = backward, b.error < (forward?.error ?? .infinity) * 0.8 { order.reverse() }

        // 每一张新接上的是内容区下面的多少行。
        let content = h - header - footer
        // 第一张从最上面开始（带着标题栏）。
        var pieces: [(index: Int, from: Int)] = [(order[0], 0)]
        var unmatched = 0
        for k in 1..<order.count {
            let a = sigs[order[k - 1]], b = sigs[order[k]]
            if let m = overlap(a, b, header: header, footer: footer), m.error < 9 {
                // b 的内容第 r 行 = a 的内容第 r + shift 行；新的从 content - shift 开始。
                if m.shift <= 0 { continue } // 一模一样的截图，跳过
                pieces.append((order[k], header + content - m.shift))
            } else {
                unmatched += 1
                pieces.append((order[k], header))
            }
        }

        // 拼：每一块从 from 到内容区底部，最后一块带上底部固定的那一截。
        let bodyEnd = h - footer
        var heights = pieces.map { bodyEnd - $0.from }
        heights[heights.count - 1] += footer
        let total = heights.reduce(0, +)
        guard total > 0, let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = 0 // 从上往下
        for (i, piece) in pieces.enumerated() {
            let img = images[piece.index]
            let rows = heights[i]
            guard let cut = img.cropping(to: CGRect(x: 0, y: piece.from, width: w, height: rows)) else { continue }
            // CGContext 原点在左下。
            ctx.draw(cut, in: CGRect(x: 0, y: total - y - rows, width: w, height: rows))
            y += rows
        }
        guard let out = ctx.makeImage() else { return nil }
        return Result(image: out, unmatched: unmatched)
    }

    // MARK: 每一行的缩略

    /// 一张图每一行压成 columns 个灰度值（0...255）。
    private struct Signature {
        let rows: Int
        let data: [Float]

        init?(_ image: CGImage) {
            let w = AutoStitch.columns, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h)
            let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                else { return false }
                ctx.interpolationQuality = .medium
                // 只横着压，竖着保留每一行。第 0 行 = 图的最上面一行。
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            rows = h
            data = bytes.map(Float.init)
        }

        /// 两行的平均差（0...255）。
        func diff(_ r: Int, _ other: Signature, _ s: Int) -> Float {
            let c = AutoStitch.columns
            var sum: Float = 0
            let a = r * c, b = s * c
            for i in 0..<c { sum += abs(data[a + i] - other.data[b + i]) }
            return sum / Float(c)
        }
    }

    /// 两张截图从上往下、从下往上各有多少行一模一样（固定的标题栏和输入框）。
    /// 状态栏的时间会变：允许少数几行不一样，只要整段大多数都一样。
    private static func fixedBands(_ a: Signature, _ b: Signature) -> (Int, Int) {
        let h = a.rows
        func scan(_ rows: [Int]) -> Int {
            var same = 0, last = 0
            for (n, r) in rows.enumerated() {
                if a.diff(r, b, r) < 1.5 {
                    same += 1
                    if Float(same) >= Float(n + 1) * 0.85 { last = n + 1 }
                }
            }
            return last
        }
        let top = scan(Array(0..<(h / 4)))
        let bottom = scan(Array((h - h / 4..<h).reversed()))
        return (top, bottom)
    }

    /// b 的内容区接在 a 下面：b 的内容第 r 行 = a 的内容第 r + shift 行。返回最合适的 shift 和平均差。
    private static func overlap(_ a: Signature, _ b: Signature, header: Int, footer: Int) -> (shift: Int, error: Float)? {
        let content = a.rows - header - footer
        guard content > 40 else { return nil }
        let minOverlap = max(content / 8, 24)
        // 先每 4 行取一行粗找，再在附近逐行细找。
        func score(_ shift: Int, step: Int) -> Float {
            let overlapRows = content - shift
            guard overlapRows >= minOverlap else { return .infinity }
            var sum: Float = 0, n: Float = 0, busy: Float = 0
            var r = 0
            while r < overlapRows {
                let d = a.diff(header + r + shift, b, header + r)
                sum += d
                n += 1
                // 这一行有没有东西（和隔壁行不一样）：全是空白的重叠不算数。
                if r + step < overlapRows, a.diff(header + r + shift, a, header + r + shift + step) > 4 { busy += 1 }
                r += step
            }
            guard n > 0, busy >= 3 else { return .infinity }
            return sum / n
        }
        var best = (shift: 0, error: Float.infinity)
        var s = 0
        while s < content - minOverlap {
            let e = score(s, step: 4)
            if e < best.error { best = (s, e) }
            s += 4
        }
        guard best.error.isFinite else { return nil }
        let center = best.shift
        var fine = (shift: center, error: Float.infinity)
        for s in max(0, center - 6)...max(0, min(content - minOverlap, center + 6)) {
            let e = score(s, step: 1)
            if e < fine.error { fine = (s, e) }
        }
        return fine.error.isFinite ? fine : best
    }
}

import ImageIO
import Photos
import UniformTypeIdentifiers

/// 主页"自动拼图"：从相册里找最近一组连续的截图（同样大小、前后几分钟内截的），拼成长图存到临时文件。
enum AutoStitchLoader {
    enum Failure: Error {
        case noAccess, notEnough, failed

        var message: String {
            switch self {
            case .noAccess: return "没有相册权限"
            case .notEnough: return "相册里最近没有连续的截图"
            case .failed: return "这几张截图拼不起来"
            }
        }
    }

    /// 一组最多几张。
    static let maxCount = 15
    /// 相邻两张截图最多隔多久还算同一组。
    static let maxGap: TimeInterval = 5 * 60

    static func run() async -> Result<URL, Failure> {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return .failure(.noAccess) }
        let assets = recentGroup()
        guard assets.count >= 2 else { return .failure(.notEnough) }
        var images: [CGImage] = []
        for asset in assets {
            if let image = await load(asset) { images.append(image) }
        }
        guard images.count >= 2 else { return .failure(.notEnough) }
        return await Task.detached(priority: .userInitiated) { () -> Result<URL, Failure> in
            guard let result = AutoStitch.stitch(images) else { return .failure(.failed) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("autostitch-\(UUID().uuidString).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                return .failure(.failed)
            }
            CGImageDestinationAddImage(dest, result.image, nil)
            return CGImageDestinationFinalize(dest) ? .success(url) : .failure(.failed)
        }.value
    }

    /// 最新的那张截图往前数，大小一样、前后隔得不久的算一组。按时间先后返回。
    private static func recentGroup() -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 40
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var group: [PHAsset] = []
        result.enumerateObjects { asset, _, stop in
            if let last = group.last {
                let gap = (last.creationDate ?? .distantPast).timeIntervalSince(asset.creationDate ?? .distantPast)
                guard asset.pixelWidth == last.pixelWidth, asset.pixelHeight == last.pixelHeight, gap <= maxGap else {
                    stop.pointee = true
                    return
                }
            }
            group.append(asset)
            if group.count >= maxCount { stop.pointee = true }
        }
        return group.reversed()
    }

    private static func load(_ asset: PHAsset) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }
}
