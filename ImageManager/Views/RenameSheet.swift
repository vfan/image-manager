import SwiftUI
import AppKit

/// Rename one file in place. Enter confirms, Escape cancels; the `.png`
/// extension is optional (added automatically) and the name is validated
/// before anything touches the disk.
public struct RenameSheet: View {
    @EnvironmentObject private var store: AppStore
    let item: ImageItem

    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public init(item: ImageItem) {
        self.item = item
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名")
                .font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(item.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            TextField("文件名", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)

            if let error = store.renameError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("留空扩展名会自动补 .png；不能包含 / 或 :")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(item.dimensionDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { store.cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear {
            name = (item.fileName as NSString).deletingPathExtension
            isFocused = true
            // Select the stem so typing replaces it, like Finder does.
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
        .onDisappear { store.renameError = nil }
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        store.rename(item, to: trimmed)
    }
}
