import SwiftUI

// MARK: - Toolbar entry

/// Toolbar button that opens the compact dimension filter.
public struct DimensionFilterButton: View {
    @EnvironmentObject private var store: AppStore
    @State private var isPresented = false

    public init() {}

    public var body: some View {
        Button {
            store.beginFilterEditing()
            isPresented = true
        } label: {
            Label("列表筛选", systemImage: store.filter.isInactive ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help(store.filter.isInactive
              ? "按长边 / 短边 / 宽 / 高筛选左侧的尺寸与比例列表"
              : "左侧列表筛选：\(store.filter.summary)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DimensionFilterPopover()
                .environmentObject(store)
        }
    }
}

// MARK: - Compact popover

/// The everyday controls: 长边 / 短边 with one-click "最多" bounds, plus a
/// straight jump to the full panel.
public struct DimensionFilterPopover: View {
    @EnvironmentObject private var store: AppStore

    public init() {}

    public var body: some View {
        let counts = store.groupRowCounts(folder: nil)
        let active = store.filter.matchingQuickBound()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("只看大图").font(.headline)
                Spacer()
                if !store.filter.isInactive {
                    Button("清除") { store.clearFilter() }
                        .buttonStyle(.link)
                }
            }

            FlowRow(spacing: 6) {
                ForEach(DimensionFilter.QuickLongSide.allCases) { bound in
                    Button {
                        if active == bound {
                            store.clearFilter()
                        } else {
                            store.applyFilter(bound.filter(scale: store.currentScale))
                        }
                    } label: {
                        Text(bound.label)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(active == bound ? .accentColor : nil)
                    .help(bound.help)
                }
            }

            Text(store.filter.isInactive
                 ? "共 \(counts.total) 组"
                 : "左侧剩 \(counts.shown) / \(counts.total) 组")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider()

            HStack {
                Button("更多条件…") {
                    store.beginFilterEditing()
                    NotificationCenter.default.post(name: .openDimensionFilterPanel, object: nil)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Compact "the left list is filtered" row shown at the top of the sidebar.
public struct SidebarFilterBar: View {
    @EnvironmentObject private var store: AppStore
    let folder: LibraryFolder?
    @State private var showEditor = false

    public init(folder: LibraryFolder?) {
        self.folder = folder
    }

    public var body: some View {
        let counts = store.groupRowCounts(folder: folder)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(.tint)
                Text("列表已筛选")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(counts.shown)/\(counts.total) 组")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(store.filter.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Button("调整") { showEditor = true }
                    .controlSize(.mini)
                Button("清除") { store.clearFilter() }
                    .controlSize(.mini)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
        .popover(isPresented: $showEditor, arrowEdge: .trailing) {
            DimensionFilterPopover().environmentObject(store)
        }
    }
}

public extension Notification.Name {
    static let openDimensionFilterPanel = Notification.Name("com.local.ImageManager.openFilterPanel")
}

// MARK: - Full panel

/// The complete editor: 长边 / 短边 / 宽 / 高, unit (px / K / dp), orientation,
/// live count, presets and remembered combos. Escape or `应用` returns to the
/// browser; `应用` also records the bounds into `filters.json`.
public struct DimensionFilterPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var isPreviewing = true
    @State private var longSideHints: [Int] = []
    /// Set by 应用 / 取消 / 清除 so `onDisappear` does not overwrite their choice.
    @State private var didFinish = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rangeRow(.longSide, helpText: "max(宽, 高)")
                    rangeRow(.shortSide, helpText: "min(宽, 高)")
                    rangeRow(.width, helpText: "只看宽度")
                    rangeRow(.height, helpText: "只看高度")

                    Picker("单位", selection: unitBinding) {
                        ForEach(DimensionUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)

                    if draft.unit == .dp {
                        Text("dp 按当前屏幕 @\(store.currentScale)x 换算（如 @2x：160 dp = 320 px）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("方向", selection: Binding(get: { draft.orientation }, set: { draft.orientation = $0 })) {
                        ForEach(DimensionFilter.OrientationPreference.allCases) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)

                    presets
                    if !store.recentCombosParsed.isEmpty { remembered }

                    inUseHints
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 620)
        .onAppear {
            store.beginFilterEditing()
            isPreviewing = true
            preview()
        }
        .task { longSideHints = store.inUseLongSides() }
        .onDisappear {
            // Leaving with the sheet still previewing keeps the draft in effect
            // and saves it, so nothing the user typed is lost.
            if isPreviewing && !didFinish { store.applyDraftFilter() }
        }
    }

    private var draft: DimensionFilter {
        get { store.draftFilter }
        nonmutating set {
            store.draftFilter = newValue
            preview()
        }
    }

    private var unitBinding: Binding<DimensionUnit> {
        Binding(get: { draft.unit }, set: { draft.unit = $0; preview() })
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("筛选左侧列表")
                    .font(.headline)
                Text("只收窄左侧的尺寸 / 比例列表，右侧图片不受影响；条件保存在本机，下次打开自动生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            let counts = store.groupRowCounts(folder: nil)
            Text("剩 \(counts.shown) / \(counts.total) 组")
                .font(.callout.monospacedDigit())
                .foregroundStyle(counts.shown == 0 ? .red : .secondary)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Toggle("实时预览", isOn: $isPreviewing)
                .toggleStyle(.checkbox)
                .onChange(of: isPreviewing) { _, on in
                    if on { preview() } else { store.cancelFilterEditing(); store.isFilterShowingDraft = false }
                }
            Spacer()
            Button("清除") {
                didFinish = true
                store.clearFilter()
                dismiss()
            }
            Button("取消") {
                didFinish = true
                store.cancelFilterEditing()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("应用") {
                didFinish = true
                store.applyDraftFilter()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func preview() {
        guard isPreviewing else { return }
        store.draftFilter = store.draftFilter.normalized()
        store.isFilterShowingDraft = true
    }

    // MARK: Rows

    private func rangeRow(_ axis: DimensionAxis, helpText: String) -> some View {
        let enabled = draft.isEnabled(axis)
        let range = draft.range(for: axis)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { on in
                        var next = draft
                        next.setEnabled(axis, on)
                        if on, next.range(for: axis).isEmpty {
                            // Seed with something sensible instead of 0 – 0.
                            let seed = next.unit.stepSuggestion[3]
                            next.setRange(axis, DimensionRange(min: nil, max: next.unit.toPixels(seed, scale: store.currentScale)))
                        }
                        draft = next
                    }
                )) {
                    Text(axis.label).font(.subheadline.weight(.medium))
                }
                .toggleStyle(.checkbox)
                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                boundField("最少", value: range.min, axis: axis)
                Text("–").foregroundStyle(.secondary)
                boundField("最多", value: range.max, axis: axis)
                Text(draft.unit.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("不限") {
                    var next = draft
                    next.setRange(axis, DimensionRange())
                    draft = next
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
        }
    }

    /// A text field that edits a pixel bound in the current unit.
    private func boundField(_ title: String, value: Int?, axis: DimensionAxis) -> some View {
        let binding = Binding<String>(
            get: {
                guard let value else { return "" }
                return String(draft.unit.fromPixels(value, scale: store.currentScale))
            },
            set: { text in
                var next = draft
                var range = next.range(for: axis)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let pixels = Int(trimmed).map { next.unit.toPixels($0, scale: store.currentScale) }
                if title == "最少" { range.min = pixels } else { range.max = pixels }
                next.setRange(axis, range)
                draft = next
            }
        )
        return TextField(title, text: binding, prompt: Text(title))
            .textFieldStyle(.roundedBorder)
            .frame(width: 92)
            .monospacedDigit()
    }

    // MARK: Presets & memory

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("常用").font(.subheadline)
            FlowRow(spacing: 6) {
                ForEach(DimensionFilter.QuickLongSide.allCases) { bound in
                    Button(bound.label) {
                        var next = bound.filter(scale: store.currentScale)
                        next.unit = draft.unit
                        draft = next
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(bound.help)
                }
            }
        }
    }

    private var remembered: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("用过的长 × 短").font(.subheadline)
            FlowRow(spacing: 6) {
                ForEach(store.recentCombosParsed) { combo in
                    Button("≤ \(combo.longSide) × ≤ \(combo.shortSide)") {
                        var next = combo.filter
                        next.unit = draft.unit
                        draft = next
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var inUseHints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("库里实际用到的长边").font(.subheadline)
            FlowRow(spacing: 6) {
                ForEach(longSideHints, id: \.self) { side in
                    Button("\(side)") {
                        var next = draft
                        next.set(.longSide, min: side, max: side)
                        draft = next
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("长边恰好为 \(side) px")
                }
                if longSideHints.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Tiny flow layout

/// Wraps children onto as many lines as needed (macOS 13+ `Layout`).
public struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    public init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
