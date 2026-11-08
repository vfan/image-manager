import SwiftUI
import AppKit

public struct ContentView: View {
    public init() {}
    @EnvironmentObject private var store: AppStore

    public var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 236, ideal: 268, max: 360)
        } detail: {
            DetailView()
        }
        .onAppear {
            store.start()
            #if DEBUG
            scheduleDebugSnapshotIfRequested()
            #endif
        }
        .sheet(item: $store.editingNoteKey) { key in
            GroupNoteEditor(key: key)
                .environmentObject(store)
        }
        .sheet(item: $store.renamingItem) { item in
            RenameSheet(item: item)
                .environmentObject(store)
        }
        .onDisappear { store.shutdown() }
    }
}

#if DEBUG
/// Test-only hook: `--snapshot <path> [--snapshot-delay N]` captures the main
/// window to a PNG after the library has had time to load, then quits.
/// Used by `scripts/smoke.sh`; it is compiled out of release builds.
func scheduleDebugSnapshotIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
    let path = args[i + 1]
    let seconds = (args.firstIndex(of: "--snapshot-delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }) ?? 6
    let clock = ContinuousClock()
    Task { @MainActor in
        // Sleep on the wall clock; `Task.sleep(for:)` uses the monotonic clock.
        try? await clock.sleep(for: .milliseconds(Int(seconds * 1000)))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            FileHandle.standardError.write("snapshot: no window\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        let view = window.contentView!
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let rep { view.cacheDisplay(in: view.bounds, to: rep) }
        if let rep, let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write("snapshot saved \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("snapshot: capture failed\n".data(using: .utf8)!)
        }
        NSApp.terminate(nil)
    }
}
#endif
