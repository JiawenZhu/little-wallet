import SwiftUI
import UIKit

/// Receipt photos, kept on the phone next to their payment: a full photo for reports and a small one for lists.
enum ReceiptVault {
    private static let cache = NSCache<NSString, UIImage>()

    static var folder: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Receipts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).jpg") }
    private static func thumbURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString)-small.jpg") }

    static func has(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    /// Keeps the photo, no larger than 2400 points on its long side, and a 240-point copy for lists.
    static func save(_ image: UIImage, for id: UUID) {
        let full = image.shrunk(to: 2400), small = image.shrunk(to: 240)
        try? full.jpegData(compressionQuality: 0.8)?.write(to: url(id), options: .atomic)
        try? small.jpegData(compressionQuality: 0.75)?.write(to: thumbURL(id), options: .atomic)
        cache.setObject(small, forKey: id.uuidString as NSString)
    }

    static func image(_ id: UUID) -> UIImage? { UIImage(contentsOfFile: url(id).path) }

    static func thumbnail(_ id: UUID) -> UIImage? {
        if let cached = cache.object(forKey: id.uuidString as NSString) { return cached }
        guard let small = UIImage(contentsOfFile: thumbURL(id).path) ?? image(id)?.shrunk(to: 240) else { return nil }
        cache.setObject(small, forKey: id.uuidString as NSString)
        return small
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: thumbURL(id))
        cache.removeObject(forKey: id.uuidString as NSString)
    }
}

extension UIImage {
    /// The photo drawn upright, no larger than `side` points on its long side.
    func shrunk(to side: CGFloat) -> UIImage {
        let scale = min(1, side / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// A receipt photo's small copy, tilted like paper on a table. Tap it to see the whole receipt.
struct ReceiptThumb: View {
    let id: UUID
    var width: CGFloat = 54

    var body: some View {
        if let small = ReceiptVault.thumbnail(id) {
            Image(uiImage: small).resizable().scaledToFill()
                .frame(width: width, height: width * 1.3)
                .clipShape(RoundedRectangle(cornerRadius: width * 0.1, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: width * 0.1, style: .continuous).strokeBorder(.white, lineWidth: max(1.5, width * 0.04)))
                .shadow(color: .black.opacity(0.15), radius: width * 0.08, y: width * 0.04)
        }
    }
}

/// The whole receipt, full screen: pinch to zoom, double-tap to zoom in, share it from here.
struct ReceiptViewer: View {
    let id: UUID
    var title: String = "Receipt"
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var settled: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragged: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if let image = ReceiptVault.image(id) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom)
                        .offset(x: offset.width + dragged.width, y: offset.height + dragged.height)
                        .gesture(MagnifyGesture()
                            .onChanged { zoom = max(1, settled * $0.magnification) }
                            .onEnded { _ in settled = zoom; if zoom == 1 { withAnimation(.snappy) { offset = .zero } } })
                        .simultaneousGesture(DragGesture()
                            .onChanged { if zoom > 1 { dragged = $0.translation } }
                            .onEnded { _ in offset.width += dragged.width; offset.height += dragged.height; dragged = .zero })
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                zoom = zoom > 1 ? 1 : 2.5; settled = zoom; offset = .zero
                            }
                        }
                } else {
                    ContentUnavailableView("Receipt photo missing", systemImage: "doc.text.magnifyingglass")
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if ReceiptVault.has(id) {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: ReceiptVault.url(id)) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
    }
}
