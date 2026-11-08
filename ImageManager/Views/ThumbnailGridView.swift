import SwiftUI
import AppKit

/// Continuous grid of every image in the current scope.
///
/// `LazyVGrid` only builds the cells that intersect the visible rect, which is
/// what keeps 100 000-image folders smooth: the view hierarchy stays at a few
/// dozen cells no matter how large the library is.
public struct ThumbnailGridView: View {
    @EnvironmentObject private var store: AppStore
    let items: [ImageItem]
    @State private var cellFrames = CellFrameBox()

    public var body: some View {
        let spacing: CGFloat = 10
        let cell = CGFloat(store.thumbnailSize)
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: spacing, alignment: .top)],
                alignment: .leading,
                spacing: spacing + 6
            ) {
                ForEach(items) { item in
                    ThumbnailCell(item: item, size: cell, showsInfo: store.showsThumbnailInfo,
                                  isSelected: store.isSelected(item))
                        .reportCellFrame(item.path)
                        .onTapGesture {
                            let flags = NSEvent.modifierFlags
                            store.clickSelect(item,
                                              command: flags.contains(.command),
                                              shift: flags.contains(.shift),
                                              in: items)
                        }
                        .contextMenu { ItemContextMenu(item: item) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: "canvas")
        .onPreferenceChange(CellFramesKey.self) { cellFrames.frames = $0 }
        .modifier(MarqueeSelector(box: cellFrames,
                                  onBegin: { store.clearSelection() },
                                  onUpdate: { store.replaceSelection($0) }))
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
