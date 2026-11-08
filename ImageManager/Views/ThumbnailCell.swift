import SwiftUI

/// A single thumbnail card. Rendering is cheap because the decoded `CGImage`
/// comes from `ThumbnailService`'s LRU cache on a hit, and loading is async on
/// a miss — the view never blocks on disk or decoding.
public struct ThumbnailCell: View {
    @EnvironmentObject private var store: AppStore
    /// Name shown in the thumbnail tooltip (helps fire tests).
    let item: ImageItem
    let size: Double
    let showsInfo: Bool
    let isSelected: Bool

    @State private var image: CGImage?

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image {
                    Checkerboard()
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                        .transition(.opacity)
                } else {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: size, height: size)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.10),
                                  lineWidth: isSelected ? 2.5 : 1)
            }

            VStack(spacing: 1) {
                if showsInfo {
                    Text(item.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.dimensionDescription)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // Creation time is always visible: it is how the list is sorted.
                Text(item.createdCaption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption2)
            .frame(width: size)
            .padding(.top, 3)
        }
        .frame(width: size)
        .contentShape(Rectangle())
        .task(id: TaskKey(id: item.id, modifiedAt: item.modifiedAt.timeIntervalSince1970, size: item.fileSize)) {
            image = nil
            if let hit = ThumbnailService.shared.cachedImage(for: item) {
                image = hit
                return
            }
            ThumbnailService.shared.load(item) { thumb in
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.12)) {
                        self.image = thumb
                    }
                }
            }
        }
        .help("\(item.relativePath)\n\(item.dimensionDescription) · \(item.fileSizeDescription)\n拖动到右侧的目录分组即可移动")
        // Drag a thumbnail out: onto another folder section (move) or to Finder.
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
        .onTapGesture(count: 2) { store.open(item) }
    }
}

/// Classic transparency checkerboard behind every preview so PNG alpha is
/// visible at a glance.
public struct Checkerboard: View {
    var cell: CGFloat = 6

    public var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.white))
            let dark = Color.black.opacity(0.06)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : cell
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(dark))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
        }
    }
}

/// Re-runs the load task when the file changes on disk (watcher refreshes the
/// item's `modifiedAt`), so edited images re-render without re-keying the whole
/// cell (which would reset layout).
private struct TaskKey: Hashable {
    let id: String
    let modifiedAt: Double
    let size: Int64
}
