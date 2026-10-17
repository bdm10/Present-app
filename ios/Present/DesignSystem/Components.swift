import SwiftUI

/// The single prominent play button on Today and Session detail.
struct PrimaryPlayButton: View {
    var isPreparing: Bool = false
    var size: CGFloat = 112
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                BreathingCircle(color: Palette.accentSoft, active: !isPreparing, minScale: 1.15, maxScale: 1.4)
                    .frame(width: size, height: size)
                Circle()
                    .fill(Palette.accent)
                    .frame(width: size, height: size)
                    .shadow(color: Palette.accent.opacity(0.25), radius: 18, y: 8)
                if isPreparing {
                    ProgressView()
                        .tint(Palette.onAccent)
                        .controlSize(.large)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: size * 0.32, weight: .regular))
                        .foregroundStyle(Palette.onAccent)
                        .offset(x: size * 0.03)
                }
            }
            .frame(width: size * 1.5, height: size * 1.5)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(isPreparing)
        .accessibilityLabel(isPreparing ? "Preparing audio" : "Play")
    }
}

/// Subtle press feedback without system tinting.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// Quiet text-style button.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.callout)
            .foregroundStyle(Palette.secondaryInk)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Rounded, filled call-to-action used sparingly.
struct SoftCapsuleButtonStyle: ButtonStyle {
    var filled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .foregroundStyle(filled ? Palette.onAccent : Palette.ink)
            .padding(.vertical, 14)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(filled ? Palette.accent : Palette.surface)
            )
            .overlay(
                Capsule().strokeBorder(filled ? Color.clear : Palette.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A small "Demo" badge so simulated content is never mistaken for live content.
struct DemoBadge: View {
    var body: some View {
        Text("Demo")
            .font(.system(.caption2, weight: .semibold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(Palette.ink.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.accentSoft))
            .accessibilityLabel("Demo content")
            .accessibilityIdentifier("demoBadge")
    }
}

/// A single-choice row of pills that wraps onto multiple lines.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var identifier: (Value) -> String = { _ in "pill" }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(.subheadline, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Palette.onAccent : Palette.ink)
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .background(Capsule().fill(isSelected ? Palette.accent : Palette.surface))
                        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Palette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier(option))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// Simple wrapping layout for pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Card container with the warm surface colour.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

/// "Presence · 10 min" line with the theme's symbol.
struct ThemeLine: View {
    let theme: Theme
    let minutes: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: theme.symbol)
            Text("\(theme.displayName) · \(minutes) min")
        }
        .eyebrowStyle()
    }
}

enum TimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        "-" + clock(seconds)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
