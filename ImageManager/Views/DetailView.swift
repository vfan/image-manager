import SwiftUI

/// Right column: toolbar, scan banner, virtualized thumbnail grid / groups,
/// inspector and status bar.
public struct DetailView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("layoutMode") private var layoutRaw = LayoutMode.groups.rawValue
    @State private var isFilterPanelPresented = false

    private var layout: LayoutMode {
        get { LayoutMode(rawValue: layoutRaw) ?? .groups }
        nonmutating set { layoutRaw = newValue.rawValue }
    }

    public var body: some View {
        let items = store.filteredItems
        VStack(spacing: 0) {
            if store.isScanning {
                ScanBanner()
            }
            content(items: items)
            StatusBar(shownCount: items.count)
        }
        .navigationTitle(store.scope.title)
        .searchable(text: $store.searchText, placement: .automatic, prompt: "搜索文件名或尺寸")
        .toolbar { toolbarContent }
        .inspector(isPresented: inspectorBinding) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .sheet(item: $store.quickLookItem) { item in
            QuickLookSheet(item: item)
        }
        .sheet(isPresented: $isFilterPanelPresented) {
            DimensionFilterPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDimensionFilterPanel)) { _ in
            isFilterPanelPresented = true
        }
        .onDeleteCommand {
            if !store.selection.isEmpty { store.requestDelete(store.selectedItems) }
        }
        .alert("删除 \(store.pendingDeletion.count) 张图片？",
               isPresented: Binding(get: { !store.pendingDeletion.isEmpty },
                                    set: { if !$0 { store.cancelDeletion() } })) {
            Button("移到废纸篓", role: .destructive) {
                store.delete(store.pendingDeletion)
            }
            Button("取消", role: .cancel) { store.cancelDeletion() }
        } message: {
            Text("文件会被移到废纸篓，可以从那里恢复。")
        }
        .focusable(false)
        .onKeyPress(.space) {
            guard let selected = store.selectedItem else { return .ignored }
            store.quickLookItem = selected
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            let dirs = urls.filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            guard let first = dirs.first else { return false }
            store.selectFolder(first)
            return true
        }
    }

    @ViewBuilder
    private func content(items: [ImageItem]) -> some View {
        if store.folders.isEmpty {
            EmptyStateView()
        } else if store.isScanning && items.isEmpty {
            ScanningPlaceholder()
        } else if items.isEmpty && !store.items.isEmpty {
            FilteredEmptyState(
                showClearSearch: !store.searchText.isEmpty,
                onClearSearch: { store.searchText = "" }
            )
        } else if items.isEmpty {
            EmptyStateView()
        } else {
            switch layout {
            case .groups:
                GroupSectionsView(items: items)
            case .grid:
                ThumbnailGridView(items: items)
            }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { store.selectedItem != nil },
            set: { shown in if !shown { store.clearSelection() } }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            DimensionFilterButton()

            Menu {
                Picker("目录", selection: Binding(
                    get: { store.scope },
                    set: { store.scope = $0 }
                )) {
                    ForEach(store.folders) { folder in
                        Text(folder.name).tag(LibraryScope.folder(folder.path))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(store.scope.title, systemImage: "folder")
            }
            .help("切换目录范围")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("分类方式", selection: $store.groupingMode) {
                    ForEach(GroupKey.Mode.allCases, id: \.self) { mode in
                        Text("按\(mode.title)").tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("按\(store.groupingMode.title)", systemImage: store.groupingMode == .exactSize
                      ? "arrow.up.left.and.arrow.down.right" : "aspectratio")
            }
            .help("分组依据：默认按精确像素尺寸")

            Picker("排序", selection: $store.sortOrder) {
                ForEach(ImageSortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 110)

            Picker("布局", selection: Binding(get: { layout }, set: { layout = $0 })) {
                Image(systemName: "square.grid.2x2").tag(LayoutMode.groups)
                Image(systemName: "rectangle.grid.3x2").tag(LayoutMode.grid)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("按分组浏览 / 连续网格")

            Slider(value: $store.thumbnailSize, in: 72...320) {
                Label("缩略图大小", systemImage: "photo")
            }
            .frame(width: 110)
            .controlSize(.small)

            Spacer(minLength: 0)

            Button {
                store.toggleQuickLook()
            } label: {
                Label("快速查看", systemImage: "eye")
            }
            .disabled(store.selectedItem == nil)
            .help("快速查看所选图片（空格）")
        }
    }
}

public enum LayoutMode: String {
    case groups
    case grid
}

// MARK: - Banner & status

private struct ScanBanner: View {
    @EnvironmentObject private var store: AppStore

    public var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(store.scanningFolderPath.map { "正在扫描：\(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "正在扫描…")
                .font(.callout)
            Text("已发现 \(store.scanProgress.files) 张 PNG")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var store: AppStore
    let shownCount: Int

    public var body: some View {
        HStack(spacing: 12) {
            Text("显示 \(shownCount) 张")
                .monospacedDigit()
            if shownCount != store.items.count {
                Text("· 全部 \(store.items.count) 张").foregroundStyle(.secondary)
            }
            if let stats = store.lastScanStats {
                Label(stats.strings, systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.secondary)
                    .help("未改动的文件直接复用索引里的路径和尺寸，不重新读取 PNG 头")
            }
            if store.selection.count > 1 {
                Label("已选 \(store.selection.count) 张", systemImage: "checkmark.circle")
                    .foregroundStyle(.tint)
            }
            if let message = store.moveMessage {
                Label(message, systemImage: "arrow.right.circle.fill")
                    .foregroundStyle(.tint)
            }
            if let largest = store.statistics.largest {
                Text("· 最大 \(largest.dimensionDescription)").foregroundStyle(.secondary)
            }
            Spacer()
            Text("编辑文件后会自动刷新")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Empty states

private struct EmptyStateView: View {
    @EnvironmentObject private var store: AppStore

    public var body: some View {
        ContentUnavailableView {
            Label("还没有目录", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("选择一个包含 PNG 图片的目录，会把其中所有 PNG 按尺寸整理出来；\n选中某个尺寸后，右侧再按子目录分类。也可以直接把目录拖进左侧边栏。")
        } actions: {
            Button(store.currentFolder == nil ? "选择目录…" : "更换目录…") { store.presentDirectoryPicker() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanningPlaceholder: View {
    public var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在读取 PNG 文件头…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FilteredEmptyState: View {
    let showClearSearch: Bool
    let onClearSearch: () -> Void

    public var body: some View {
        ContentUnavailableView {
            Label("没有匹配的图片", systemImage: "magnifyingglass")
        } description: {
            Text("换个关键词试试。")
        } actions: {
            if showClearSearch {
                Button("清除搜索", action: onClearSearch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Group overview

/// One section of the right-hand list. When the sidebar selects a folder the
/// sections are pixel sizes / ratios; when it selects a size or ratio group the
/// sections become **folders**, which is also what makes drag-to-move possible.
private struct DetailSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let items: [ImageItem]
    /// Set when this section is a size / ratio group.
    let key: GroupKey?
    /// Set when this section is a subdirectory (drop target for moving).
    let target: AppStore.Subdirectory?
    let aspect: Double?
}

/// The default browser: every image of the current selection, grouped either by
/// size or by folder, laid out in rows whose column count follows the window
/// width and the thumbnail size slider. Rows live in a single `LazyVStack`, so
/// only the rows you can see are ever built.
public struct GroupSectionsView: View {
    @EnvironmentObject private var store: AppStore
    let items: [ImageItem]
    @State private var cellFrames = CellFrameBox()

    private func sections() -> [DetailSection] {
        let groupedBySubdirectory: Bool
        if case .group = store.scope { groupedBySubdirectory = true } else { groupedBySubdirectory = false }

        if groupedBySubdirectory {
            // Selected a size / ratio: show which subdirectories hold them.
            let root = store.currentFolder?.path ?? ""
            return AppStore.subdirectorySections(items: items, root: root).map { pair in
                DetailSection(id: "subdir:" + pair.directory.id,
                              title: pair.directory.title,
                              subtitle: pair.items.first?.createdCaption ?? "",
                              items: pair.items,
                              key: nil,
                              target: pair.directory,
                              aspect: nil)
            }
        }

        // Selected a folder (or nothing): group by the chosen size dimension.
        var map: [String: [ImageItem]] = [:]
        var keys: [String: GroupKey] = [:]
        for item in items {
            let key = AppStore.groupKey(for: item, mode: store.groupingMode)
            map[key.id, default: []].append(item)
            keys[key.id] = key
        }
        return keys.values
            .sorted { Self.isOrderedBefore($0, $1) }
            .map { key in
                let groupItems = (map[key.id] ?? []).sorted { Self.isOrderedBefore($0, $1) }
                let subtitle: String
                if store.groupingMode == .exactSize {
                    subtitle = key.category?.rawValue
                        ?? key.displayAspect.map { String(format: "%.2f:1", $0) } ?? ""
                } else {
                    subtitle = key.mode.title
                }
                return DetailSection(id: key.id, title: key.title, subtitle: subtitle,
                                     items: groupItems, key: key, target: nil,
                                     aspect: key.displayAspect)
            }
    }

    /// Bigger images first, then by name — inside a section and across groups.
    private static func isOrderedBefore(_ lhs: ImageItem, _ rhs: ImageItem) -> Bool {
        if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
        return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
    }

    private static func isOrderedBefore(_ lhs: GroupKey, _ rhs: GroupKey) -> Bool {
        switch lhs.groupMode {
        case .aspect:
            return (lhs.category?.sortRank ?? 99) < (rhs.category?.sortRank ?? 99)
        case .exactSize:
            let l = lhs.width * lhs.height, r = rhs.width * rhs.height
            if l != r { return l > r }
            return lhs.width > rhs.width
        case .width, .area:
            return lhs.bucket < rhs.bucket
        }
    }

    // MARK: Feed

    private struct FeedRow: Identifiable {
        enum Content {
            case header(DetailSection)
            case strip(DetailSection, [ImageItem])
        }

        let id: String
        let content: Content
    }

    private func feed(width: CGFloat, sections: [DetailSection]) -> [FeedRow] {
        let spacing: CGFloat = 10
        let cell = CGFloat(store.thumbnailSize)
        let usable = max(cell, width - 40)          // 20pt padding on each side
        let columns = max(1, Int((usable + spacing) / (cell + spacing)))

        var rows: [FeedRow] = []
        rows.reserveCapacity(items.count / columns + sections.count * 2)
        for section in sections {
            rows.append(FeedRow(id: "h:" + section.id, content: .header(section)))
            var index = 0
            while index < section.items.count {
                let end = min(index + columns, section.items.count)
                rows.append(FeedRow(id: "r:\(section.id):\(index)",
                                    content: .strip(section, Array(section.items[index..<end]))))
                index = end
            }
        }
        return rows
    }

    public var body: some View {
        let sections = sections()
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(feed(width: geo.size.width, sections: sections)) { row in
                        switch row.content {
                        case let .header(section):
                            SectionHeaderView(section: section)
                                .padding(.top, 12)
                        case let .strip(section, slice):
                            ThumbnailRow(section: section, items: slice)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "canvas")
            .onPreferenceChange(CellFramesKey.self) { cellFrames.frames = $0 }
            .modifier(MarqueeSelector(box: cellFrames,
                                      onBegin: { store.clearSelection() },
                                      onUpdate: { store.replaceSelection($0) }))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One line of thumbnails: all from the same section, so a drop here means
/// "move into this folder".
private struct ThumbnailRow: View {
    @EnvironmentObject private var store: AppStore
    let section: DetailSection
    let items: [ImageItem]
    @State private var isDropTargeted = false

    public var body: some View {
        let cell = CGFloat(store.thumbnailSize)
        HStack(alignment: .top, spacing: 10) {
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
                    .contextMenu {
                        ItemContextMenu(item: item)
                    }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(4)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .modifier(SubdirectoryDropTarget(target: section.target, isTargeted: $isDropTargeted))
    }
}

/// Adds `.dropDestination` only when the section is a subdirectory.
private struct SubdirectoryDropTarget: ViewModifier {
    @EnvironmentObject private var store: AppStore
    let target: AppStore.Subdirectory?
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        if let target {
            content.dropDestination(for: URL.self) { urls, _ in
                store.moveFiles(urls, to: target) > 0
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else {
            content
        }
    }
}

/// Group title, count, note and the small "jump to this group" affordances.
private struct SectionHeaderView: View {
    @EnvironmentObject private var store: AppStore
    let section: DetailSection
    @State private var isDropTargeted = false

    private var exactSizes: [(key: GroupKey, count: Int)] {
        let stats = LibraryStatistics.make(from: section.items)
        return stats.exactSizeGroups.prefix(6).map { (.exactSize($0), $0.count) }
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let target = section.target {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                    .font(.callout)
                Text(target.title)
                    .font(.title3.weight(.semibold))
                if !section.subtitle.isEmpty {
                    Text("最新 \(section.subtitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(section.items.count) 张")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isDropTargeted {
                    Label("松开即可移动到这里", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else {
                    Text("拖图片到这里可移动进来")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else if let key = section.key {
                ShapeBadge(aspect: section.aspect, tint: .accentColor)
                    .frame(width: 26, height: 18)
                Text(section.title)
                    .font(.title3.weight(.semibold))
                if !section.subtitle.isEmpty {
                    Text(section.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(section.items.count) 张")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let note = store.noteText(for: key) {
                    GroupNoteLabel(text: note)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.10), in: Capsule())
                } else {
                    Button {
                        store.beginEditingNote(for: key)
                    } label: {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("给这一组加备注")
                }
                Spacer()
                if store.groupingMode != .exactSize {
                    ForEach(exactSizes, id: \.key.id) { size in
                        Button {
                            store.scope = .group(size.key)
                        } label: {
                            Text(size.key.title)
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("只看 \(size.key.title)（\(size.count) 张）")
                    }
                }
                Button("在侧栏中筛选") { store.scope = .group(key) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .contextMenu {
                        GroupNoteMenuItems(key: key)
                        Divider()
                        Button("只看这一组") { store.scope = .group(key) }
                    }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(isDropTargeted ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .modifier(SubdirectoryDropTarget(target: section.target, isTargeted: $isDropTargeted))
    }
}

// MARK: - Context menu

public struct ItemContextMenu: View {
    @EnvironmentObject private var store: AppStore
    let item: ImageItem

    public var body: some View {
        Button("用默认应用打开") { store.open(item) }
        Button("在访达中显示") { store.reveal(item) }
        Button("快速查看") {
            store.selectedItemID = item.path
            store.toggleQuickLook()
        }
        Divider()
        Button("重命名…") { store.beginRename(item) }
        Button("复制路径") { store.copyPath(item) }
        Button("复制尺寸") { store.copyDimensions(item) }
        Divider()
        let deleteTargets = store.isSelected(item) && store.selection.count > 1
            ? store.selectedItems
            : [item]
        Button(deleteTargets.count > 1 ? "删除 \(deleteTargets.count) 张（移到废纸篓）" : "删除（移到废纸篓）",
               role: .destructive) {
            store.requestDelete(deleteTargets)
        }
        Divider()
        let targets = store.moveTargets(for: item)
        if !targets.isEmpty {
            Menu("移动到子目录") {
                ForEach(targets) { target in
                    Button(target.title) { store.move(item, to: target) }
                        .help(target.url.path)
                }
            }
        }
        Divider()
        Button("以此尺寸筛选长边") {
            var next = store.filter
            let side = max(item.pixelWidth, item.pixelHeight)
            next.set(.longSide, min: side, max: side)
            store.applyFilter(next)
        }
        Button("取消列表筛选") { store.clearFilter() }
            .disabled(store.filter.isInactive)
    }
}
