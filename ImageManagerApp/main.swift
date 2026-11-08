import SwiftUI
import ImageManagerCore

@main
struct ImageManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppStore

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        AppDelegate.sharedStore = store
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button(store.currentFolder == nil ? "选择目录…" : "更换目录…") {
                    store.presentDirectoryPicker()
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("重新扫描当前目录") { store.rescanCurrentFolder() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("重新扫描（忽略缓存）") { store.rescanCurrentFolder(forceRefresh: true) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("重命名…") {
                    if let item = store.selectedItem { store.beginRename(item) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.selectedItem == nil)
                Button(store.selection.count > 1
                       ? "删除 \(store.selection.count) 张（移到废纸篓）"
                       : "删除（移到废纸篓）") {
                    store.requestDelete(store.selectedItems)
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.selection.isEmpty)
            }
            CommandMenu("筛选") {
                Button("按长宽筛选…") { store.presentFilterPanel() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("清除长宽筛选") { store.clearFilter() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(store.filter.isInactive)
                Divider()
                ForEach(DimensionFilter.QuickLongSide.allCases) { bound in
                    Button(bound.label) { store.applyQuickBound(bound) }
                }
            }
            CommandMenu("显示") {
                Toggle("显示缩略图信息", isOn: $store.showsThumbnailInfo)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("放大缩略图") { store.increaseThumbnailSize() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("缩小缩略图") { store.decreaseThumbnailSize() }
                    .keyboardShortcut("-", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedStore: AppStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic command-line utilities (see README) are handled here,
        // before the window even appears.
        let diagnosticFlags = ["--add-folder", "--scan-and-export", "--scope", "--sort", "--filter", "--search", "--thumb-size"]
        if diagnosticFlags.contains(where: CommandLine.arguments.contains) {
            AppDelegate.sharedStore?.runLaunchArguments()
        }
    }
}
