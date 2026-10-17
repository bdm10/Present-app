import SwiftUI

/// A soft circle that slowly expands (4 s inhale) and settles (6 s exhale).
/// Driven by `TimelineView` so it needs no state and pauses cleanly.
struct BreathingCircle: View {
    var color: Color = Palette.accentSoft
    var active: Bool = true
    var minScale: CGFloat = 0.82
    var maxScale: CGFloat = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool {
        active && !reduceMotion && !LaunchOptions.current.isUITest
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let progress = animates ? BreathingCircle.progress(at: context.date) : 0.6
            let scale = minScale + (maxScale - minScale) * progress
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(0.95), color.opacity(0.35)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 220
                        )
                    )
                Circle()
                    .strokeBorder(color.opacity(0.6), lineWidth: 1)
                    .scaleEffect(1.08)
                    .opacity(0.4 + 0.4 * progress)
            }
            .scaleEffect(scale)
        }
        .accessibilityHidden(true)
    }

    /// 0…1 over a 10 s cycle: ease in for 4 s, ease out for 6 s.
    static func progress(at date: Date) -> CGFloat {
        let cycle = 10.0
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        if t < 4 {
            return ease(t / 4)
        } else {
            return 1 - ease((t - 4) / 6)
        }
    }

    private static func ease(_ x: Double) -> CGFloat {
        CGFloat(0.5 - 0.5 * cos(Double.pi * x))
    }
}
