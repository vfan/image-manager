import SwiftUI

/// Modal quick look, wired from the toolbar / context menu / space bar.
public struct QuickLookSheet: View {
    let item: ImageItem
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName).font(.headline)
                    Text("\(item.dimensionDescription) · \(item.fileSizeDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if let nsImage = NSImage(contentsOf: item.url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("无法解码此图片", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 420, idealHeight: 620)
    }
}
