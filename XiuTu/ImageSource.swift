import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 选回来的一张图：用的时候再读数据。
typealias ImageLoader = () async -> Data?

extension View {
    /// 选图：手机上从相册选，Mac 上从文件选（Mac 版不用相册）。
    func imageSource(isPresented: Binding<Bool>, limit: Int = 1, onPick: @escaping ([ImageLoader]) -> Void) -> some View {
        modifier(ImageSourceModifier(isPresented: isPresented, limit: limit, onPick: onPick))
    }
}

private struct ImageSourceModifier: ViewModifier {
    @Binding var isPresented: Bool
    let limit: Int
    let onPick: ([ImageLoader]) -> Void
    @State private var picked: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        if Platform.isMac {
            content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.image],
                                 allowsMultipleSelection: limit > 1) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                onPick(urls.prefix(max(limit, 1)).map { url in
                    {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try? Data(contentsOf: url)
                    }
                })
            }
        } else {
            content
                .photosPicker(isPresented: $isPresented, selection: $picked, maxSelectionCount: max(limit, 1), matching: .images)
                .onChange(of: picked) { _, items in
                    guard !items.isEmpty else { return }
                    onPick(items.map { item in { try? await item.loadTransferable(type: Data.self) } })
                    picked = []
                }
        }
    }
}
