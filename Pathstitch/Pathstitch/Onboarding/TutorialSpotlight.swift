import SwiftUI

// MARK: - Tutorial spotlight infrastructure
//
// The first-run "Getting Started" tour points at the actual tool/panel the user
// should use and advances on its own once they've done the step's action (drawn a
// circle, applied a fillet, …). This file holds the plumbing: each spotlightable
// view registers its on-screen frame via `.tutorialAnchor(_:)`, the overlay reads
// those frames to draw a glowing ring, and `TutorialController` carries the live
// step + scroll target between `ContentView` and `OnboardingModifier`.

/// Identifies a UI element the tutorial can spotlight. Toolbar tools are keyed by
/// their `TwoDTool`; the two flyout buttons and the Layers panel get their own
/// cases so a step can point at whichever element actually hosts the tool (a tool
/// living in the Shapes/More flyout is reached through its flyout button).
enum TutorialHighlight: Hashable {
    case tool(TwoDTool)
    case shapesFlyout
    case extraFlyout
    case layersPanel
}

/// Collects the frame (as an `Anchor<CGRect>`) of every spotlightable element,
/// keyed by `TutorialHighlight`. Views register through `.tutorialAnchor(_:)`.
struct TutorialAnchorKey: PreferenceKey {
    static let defaultValue: [TutorialHighlight: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TutorialHighlight: Anchor<CGRect>],
                       nextValue: () -> [TutorialHighlight: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Registers this view's bounds so the tutorial can spotlight it. Cheap and
    /// always-on; the ring is only drawn while a step that targets it is active.
    func tutorialAnchor(_ id: TutorialHighlight) -> some View {
        anchorPreference(key: TutorialAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

/// What a tutorial step asks the user to focus on. `.tool` resolves through the
/// live toolbar layout to the on-screen element that hosts that tool.
enum SpotlightTarget {
    case tool(TwoDTool)
    case layersPanel
}

/// The stable toolbar-item id for a tool, used for layout lookups and scrolling.
@MainActor
func tutorialToolItemId(_ tool: TwoDTool) -> String? {
    ToolbarRegistry.all.first { $0.kind == .tool(tool) }?.id
}

/// Shared, observable tutorial state. Lives in `ContentView` so both the
/// onboarding overlay and the left toolbar (which scrolls the target into view)
/// can read it.
@MainActor
@Observable
final class TutorialController {
    /// Index into `pathstitchTutorialSteps`, or nil when the tour isn't running.
    var step: Int? = nil
    /// A `ScrollViewReader` id the left toolbar should scroll to so the current
    /// step's tool is visible, or nil (no scroll needed).
    var scrollTarget: String? = nil
}

/// Snapshot of the document taken when a step begins, so completion can be judged
/// against "what changed since this step started" rather than absolute counts.
struct TutorialBaseline {
    let circleCount: Int
    let polylineCount: Int
    let filletedCorners: Int
    let undoDepth: Int

    @MainActor
    init(_ s: AppState) {
        circleCount = TutorialBaseline.circles(in: s)
        polylineCount = TutorialBaseline.polylines(in: s)
        filletedCorners = TutorialBaseline.filletedCorners(in: s)
        undoDepth = s.undoStack.count
    }

    /// Number of corners across all parametric shapes that carry a non-zero
    /// fillet/chamfer — a jump means the user actually rounded a corner.
    @MainActor
    static func filletedCorners(in s: AppState) -> Int {
        s.parametricShapes.values.reduce(0) { acc, shape in
            acc + shape.corners.filter { $0.value > 1e-9 }.count
        }
    }

    @MainActor
    static func circles(in s: AppState) -> Int {
        s.entities.filter { $0.type.uppercased() == "CIRCLE" }.count
    }

    /// Polyline count — a drawn rectangle (or polygon) bakes to an LWPOLYLINE, so a
    /// jump here means the user added a rectangle during the step. The `closed`
    /// flag isn't required (it can be absent on freshly added geometry).
    @MainActor
    static func polylines(in s: AppState) -> Int {
        s.entities.filter {
            let t = $0.type.uppercased()
            return t == "LWPOLYLINE" || t == "POLYLINE"
        }.count
    }
}

/// A pulsing accent ring drawn around a spotlighted element's frame — the "box
/// gets brighter" cue. Non-interactive so the user can still click through to the
/// real tool underneath.
struct SpotlightRing: View {
    let rect: CGRect
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.accent, lineWidth: 2.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accent.opacity(0.14))
            )
            .frame(width: rect.width + 10, height: rect.height + 10)
            .shadow(color: Color.accent.opacity(pulse ? 0.85 : 0.35),
                    radius: pulse ? 11 : 4)
            .opacity(pulse ? 1.0 : 0.7)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { pulse = true }
            .allowsHitTesting(false)
    }
}
