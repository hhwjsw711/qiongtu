import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// 历史图库里的一张图。
struct HistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    /// 从哪个功能存进来的（修图、封神、摄影棚……）。
    let source: String
    /// 文件扩展名：jpg / heic / png。
    let ext: String
    let width: Int
    let height: Int
}

/// 历史图库：保存图片时可以顺手在 App 里留一份。图存在 App 自己的目录里，不进相册。
/// 可以设密码：密码只存一份加盐的摘要在钥匙串里；它锁的是进图库的门，文件本身靠系统的锁屏加密保护。
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    /// 新的在前。
    private(set) var items: [HistoryItem] = []
    /// 保存图片时要不要同时存一份进来。
    private(set) var enabled: Bool
    private(set) var hasPassword: Bool

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let thumbs = NSCache<NSUUID, UIImage>()
    private static let passwordAccount = "history.password"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        enabled = UserDefaults.standard.object(forKey: "history.enabled") as? Bool ?? true
        hasPassword = !Keychain.get(Self.passwordAccount).isEmpty
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            // 文件不在了的条目不要。
            items = list.filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "history.enabled")
    }

    // MARK: 文件

    func fileURL(_ item: HistoryItem) -> URL {
        folder.appendingPathComponent(item.id.uuidString + "." + item.ext)
    }

    private func thumbURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString + ".thumb.jpg")
    }

    private func recipeURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString + ".recipe.json")
    }

    /// 这张图的处理步骤（从修图存进来的才有）。
    func recipe(_ id: UUID) -> EditRecipe? {
        guard let data = try? Data(contentsOf: recipeURL(id)) else { return nil }
        return try? JSONDecoder().decode(EditRecipe.self, from: data)
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: folder.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
    }

    /// 存一张进来。ext 是 jpg / heic / png。
    func add(data: Data, ext: String, source: String, recipe: EditRecipe? = nil) async {
        let id = UUID()
        if let recipe, !recipe.steps.isEmpty, let json = try? JSONEncoder().encode(recipe) {
            try? json.write(to: recipeURL(id), options: [.atomic, .completeFileProtection])
        }
        let file = folder.appendingPathComponent(id.uuidString + "." + ext)
        let thumb = thumbURL(id)
        let size = await Task.detached(priority: .utility) { () -> (Int, Int)? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            do {
                try data.write(to: file, options: [.atomic, .completeFileProtection])
            } catch {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) {
                try? jpeg.write(to: thumb, options: [.atomic, .completeFileProtection])
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            var w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            var h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            // 方向是横过来存的，宽高要对调。
            if let o = props?[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
            return (w, h)
        }.value
        guard let size else { return }
        items.insert(HistoryItem(id: id, date: Date(), source: source, ext: ext, width: size.0, height: size.1), at: 0)
        saveIndex()
    }

    func add(image: UIImage, source: String) async {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return }
        await add(data: data, ext: "jpg", source: source)
    }

    /// 小图：先看内存里有没有，没有就从文件读。
    func thumbnail(_ item: HistoryItem) async -> UIImage? {
        if let hit = thumbs.object(forKey: item.id as NSUUID) { return hit }
        let url = thumbURL(item.id)
        let fallback = fileURL(item)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { return image }
            // 小图丢了就用原图现缩一张。
            guard let source = CGImageSourceCreateWithURL(fallback as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
        if let image { thumbs.setObject(image, forKey: item.id as NSUUID) }
        return image
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            try? FileManager.default.removeItem(at: fileURL(item))
            try? FileManager.default.removeItem(at: thumbURL(item.id))
            try? FileManager.default.removeItem(at: recipeURL(item.id))
            thumbs.removeObject(forKey: item.id as NSUUID)
        }
        items.removeAll { ids.contains($0.id) }
        saveIndex()
    }

    func clear() {
        delete(Set(items.map(\.id)))
    }

    // MARK: 密码

    private static func digest(_ password: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + password).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func setPassword(_ password: String) {
        let salt = UUID().uuidString
        Keychain.set(salt + ":" + Self.digest(password, salt: salt), account: Self.passwordAccount)
        hasPassword = true
    }

    func removePassword() {
        Keychain.set("", account: Self.passwordAccount)
        hasPassword = false
    }

    func check(_ password: String) -> Bool {
        let parts = Keychain.get(Self.passwordAccount).split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        return Self.digest(password, salt: parts[0]) == parts[1]
    }
}
