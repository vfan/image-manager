import SwiftUI

/// Small editor for a group note ("2048 × 2048 → iOS 截屏").
public struct GroupNoteEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let key: GroupKey
    @State private var text = ""
    @FocusState private var isFocused: Bool

    public init(key: GroupKey) {
        self.key = key
        _text = State(initialValue: "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.note(for: key) == nil ? "给这一组加个备注" : "编辑备注")
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(key.title).monospacedDigit()
                    Text("·").foregroundStyle(.secondary)
                    Text("\(key.mode.title)分组").foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    Text("\(count) 张").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
            }

            TextField("例如：iOS 截屏、公众号封面、图标素材", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .focused($isFocused)

            Text("备注只保存在本机（notes.json），会显示在左侧列表里；搜索备注也能筛出这一组的图片。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if store.note(for: key) != nil {
                    Button("删除备注", role: .destructive) {
                        store.removeNote(for: key)
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    store.setNote(text, for: key)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && store.note(for: key) == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            text = store.noteText(for: key) ?? ""
            isFocused = true
        }
    }

    /// How many images are in this group right now.
    private var count: Int {
        store.items.filter { key.matches($0) }.count
    }
}

/// The little blue note shown next to a group in the sidebar / section header.
public struct GroupNoteLabel: View {
    let text: String
    var compact = false

    public init(text: String, compact: Bool = false) {
        self.text = text
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.tint)
            Text(text)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
        }
    }
}

/// Context-menu items shared by the sidebar row and the section header.
public struct GroupNoteMenuItems: View {
    @EnvironmentObject private var store: AppStore
    let key: GroupKey

    public init(key: GroupKey) {
        self.key = key
    }

    public var body: some View {
        if let note = store.note(for: key) {
            Button("编辑备注…") { store.beginEditingNote(for: key) }
            Button("删除备注“\(note.text)”", role: .destructive) { store.removeNote(for: key) }
        } else {
            Button("添加备注…") { store.beginEditingNote(for: key) }
        }
    }
}
