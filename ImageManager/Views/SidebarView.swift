import SwiftUI
import UniformTypeIdentifiers

/// Left column: library folders, grouping mode and the size groups it produces.
public struct SidebarView: View {
    public init() {}
    @EnvironmentObject private var store: AppStore
    @AppStorage("groupFolderPath") private var groupFolderPath = ""
    @State private var isDropTargeted = false

    private var groupingMode: GroupKey.Mode {
        get { store.groupingMode }
        nonmutating set { store.groupingMode = newValue }
    }

    private var groupingFolder: LibraryFolder? {
        store.folders.first { $0.path == groupFolderPath }
    }

    public var body: some View {
        List(selection: Binding(
            get: { store.scope.sidebarSelectionID },
            set: { newValue in
                guard let id = newValue else { return }
                store.scope = Self.scope(from: id)
            }
        )) {
            if !store.effectiveFilter.isInactive {
                Section { SidebarFilterBar(folder: groupingFolder) }
            }
            foldersSection
            librarySection
            groupsSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay(alignment: .center) {
            if isDropTargeted {
                dropOverlay
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.presentDirectoryPicker()
                } label: {
                    Label(store.currentFolder == nil ? "选择目录" : "更换目录", systemImage: "folder")
                }
                .help("选择图片目录；再次点击可更换（⌘O）")
            }
        }
    }

    // MARK: Sections

    private var foldersSection: some View {
        Section("目录") {
            ForEach(store.folderCounts, id: \.folder.id) { entry in
                Label {
                    HStack {
                        Text(entry.folder.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text("\(entry.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(.tint)
                }
                .tag("folder:" + entry.folder.path)
                .contextMenu {
                    Button("在访达中显示") { store.revealFolders(entry.folder.path) }
                    Button("重新扫描") {
                        if let folder = store.folders.first(where: { $0.path == entry.folder.path }) {
                            Task { await store.scan(folder: folder) }
                        }
                    }
                    Divider()
                    Button("从图库中移除", role: .destructive) { store.removeFolder(entry.folder.path) }
                }
                .help(entry.folder.path)
            }
            Button {
                store.presentDirectoryPicker()
            } label: {
                Label(store.currentFolder == nil ? "选择目录…" : "更换目录…", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var librarySection: some View {
        if store.statistics.duplicateNameCount > 0 {
            Section("图库") {
                Label {
                    Text("重名文件 \(store.statistics.duplicateNameCount)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.secondary)
                    .help("有 \(store.statistics.duplicateNameCount) 个文件与其他目录中的文件同名")
            }
        }
    }

    private var groupsSection: some View {
        let folder = groupingFolder
        let rows = store.groupRows(for: groupingMode, folder: folder)
        return Section {
            ForEach(rows, id: \.key.id) { row in
                GroupRowView(key: row.key, count: row.count)
                    .tag(StoreScopeID.group(row.key))
                    .contentShape(Rectangle())
            }
            if rows.isEmpty {
                Text(store.effectiveFilter.isInactive ? "没有可归类的图片" : "当前筛选下没有符合条件的\(groupingMode.title)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                if !store.effectiveFilter.isInactive {
                    Button("清除列表筛选") { store.clearFilter() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text("按\(groupingMode.title)分类")
                Spacer()
                Menu {
                    Picker("分类方式", selection: Binding(
                        get: { groupingMode },
                        set: { groupingMode = $0; if $0 != .exactSize { groupFolderPath = "" } }
                    )) {
                        ForEach(GroupKey.Mode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    if !store.folders.isEmpty {
                        Picker("统计范围", selection: $groupFolderPath) {
                            Text("全部目录").tag("")
                            ForEach(store.folders) { folder in
                                Text(folder.name).tag(folder.path)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(groupingMode.help)
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.scanningFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "扫描中")
                        .font(.caption)
                        .lineLimit(1)
                    Text("已发现 \(store.scanProgress.files) 张")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("\(store.statistics.totalCount) 张 PNG · \(ByteCountFormatter.string(fromByteCount: store.statistics.totalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.rescanCurrentFolder()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isScanning)
            .help("重新扫描（⌘R）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var dropOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus").font(.largeTitle)
            Text("松开即可使用这个目录").font(.headline)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(.tint)
                .padding(6)
        )
    }

    // MARK: Helpers

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collected = URLCollector()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let directories = collected.urls.filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            if let first = directories.first { store.selectFolder(first) }
        }
        return true
    }

    /// Parses sidebar selection tags back into a `LibraryScope`.
    static func scope(from id: String) -> LibraryScope {
        LibraryScope(selectionID: id) ?? .all
    }
}

private enum StoreScopeID {
    static func group(_ key: GroupKey) -> String { "group:" + key.id }
}

// MARK: - Group row

private struct GroupRowView: View {
    @EnvironmentObject private var store: AppStore
    let key: GroupKey
    let count: Int

    public var body: some View {
        HStack(spacing: 8) {
            ShapeBadge(aspect: key.displayAspect, tint: key.mode == .aspect ? .accentColor : .secondary)
                .frame(width: 22, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(key.title)
                    .lineLimit(1)
                if let note = store.noteText(for: key) {
                    GroupNoteLabel(text: note, compact: true)
                } else if key.mode != .aspect {
                    Text(key.mode.title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(store.noteText(for: key).map { "\(key.title) · \(count) 张\n备注：\($0)" }
              ?? "\(key.title) · \(count) 张")
        .contextMenu {
            GroupNoteMenuItems(key: key)
            Divider()
            Button("只看这一组") { store.scope = .group(key) }
        }
    }
}

/// Renders a tiny shape (rectangle / square / phone) at the group's aspect ratio.
public struct ShapeBadge: View {
    let aspect: Double?
    let tint: Color

    public var body: some View {
        GeometryReader { geo in
            let available = geo.size
            let ratio = aspect ?? 4.0 / 3.0
            let h = min(available.height, available.width / ratio)
            let w = h * ratio
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(tint, lineWidth: 1.5)
                .frame(width: w, height: h)
                .position(x: available.width / 2, y: available.height / 2)
        }
    }
}

/// Small lock-protected box for collecting URLs from `NSItemProvider` callbacks.
private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func add(_ url: URL) {
        lock.lock(); storage.append(url); lock.unlock()
    }
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
