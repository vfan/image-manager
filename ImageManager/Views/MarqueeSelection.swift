import SwiftUI
import AppKit

/// Collects the on-screen frame of every visible thumbnail in the "canvas"
/// coordinate space, so a rubber-band drag can tell what it covers.
struct CellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Reports this cell's frame for marquee hit-testing.
    func reportCellFrame(_ id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: CellFramesKey.self,
                                       value: [id: proxy.frame(in: .named("canvas"))])
            }
        }
    }
}

/// Holds cell frames outside SwiftUI state: updating it must not re-render the
/// whole grid on every scroll tick.
final class CellFrameBox {
    var frames: [String: CGRect] = [:]
}

/// Rubber-band selection over empty space. Dragging on a thumbnail still starts
/// a drag-and-drop, which is why the gesture only arms when it begins outside
/// every cell.
struct MarqueeSelector: ViewModifier {
    let box: CellFrameBox
    let onBegin: () -> Void
    let onUpdate: (Set<String>) -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var rect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let rect, rect.width > 1, rect.height > 1 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("canvas"))
                    .onChanged { value in
                        if start == nil {
                            // Only start on empty space, never on a thumbnail.
                            guard !box.frames.values.contains(where: { $0.contains(value.startLocation) })
                            else { return }
                            start = value.startLocation
                            onBegin()
                        }
                        guard start != nil else { return }
                        current = value.location
                        guard let rect else { return }
                        onUpdate(Set(box.frames.filter { $0.value.intersects(rect) }.keys))
                    }
                    .onEnded { _ in
                        start = nil
                        current = nil
                    }
            )
    }
}
