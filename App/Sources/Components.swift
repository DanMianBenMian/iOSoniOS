import SwiftUI

/// A stepped, draggable bar. Values are discrete tiers; the fill and the
/// number animate only when the tier changes (state change, not continuous).
struct TierSlider: View {
    let tiers: [Double]
    @Binding var index: Int
    let label: (Double) -> String
    var tint: Color = Theme.accent

    @State private var dragIndex: Int? = nil
    private let h: CGFloat = 6

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceHi).frame(height: h)
                    Capsule().fill(tint)
                        .frame(width: max(h, w * CGFloat(current) / CGFloat(max(1, tiers.count - 1))), height: h)
                        .animation(.easeOut(duration: 0.25), value: current)

                    ForEach(tiers.indices, id: \.self) { i in
                        Circle()
                            .fill(i <= current ? tint : Theme.textFaint.opacity(0.55))
                            .frame(width: i == current ? 13 : 8, height: i == current ? 13 : 8)
                            .position(x: w * CGFloat(i) / CGFloat(max(1, tiers.count - 1)), y: h / 2)
                            .animation(.easeOut(duration: 0.25), value: current)
                    }
                }
                .frame(height: h)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = min(1, max(0, value.location.x / w))
                        dragIndex = Int((p * Double(tiers.count - 1)).rounded())
                    }
                    .onEnded { _ in
                        if let d = dragIndex { index = d }
                        dragIndex = nil
                    })
                .onTapGesture { location in
                    let p = min(1, max(0, location.x / w))
                    index = Int((p * Double(tiers.count - 1)).rounded())
                }
            }
            .frame(height: h)

            HStack {
                Text(label(tiers.first ?? 0))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textFaint)
                Spacer()
                Text(label(tiers.last ?? 0))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textFaint)
            }
        }
        .onChange(of: dragIndex) { new in
            if let d = new, d != index { index = d }
        }
    }

    private var current: Int { dragIndex ?? index }
}

/// Number that rolls to its new value on change.
struct RollingNumber: View {
    let value: String
    var font: Font = .system(size: 20, weight: .medium, design: .monospaced)
    var color: Color = Theme.text

    var body: some View {
        Text(value)
            .font(font)
            .foregroundColor(color)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: value)
    }
}

/// A settings-style row: icon, title, optional subtitle, trailing content.
struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let iconColor: Color
    @ViewBuilder let content: Content

    init(icon: String, title: String, subtitle: String? = nil,
         iconColor: Color = Theme.accent,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.iconColor = iconColor
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
            }
            Spacer(minLength: 8)
            content
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.surface)
        .cornerRadius(12)
    }
}
