import SwiftUI

/// The running-VM surface: pure black, minimal chrome, a collapsible floating
/// key cluster in Liquid Glass, and the guest's own console output.
struct VMView: View {
    let config: VMConfig
    @StateObject private var engine: BootEngine
    @Environment(\.dismiss) private var dismiss

    @State private var keysExpanded = false      // collapsed by default
    @State private var showLog = true

    init(config: VMConfig) {
        self.config = config
        _engine = StateObject(wrappedValue: BootEngine(config: config))
    }

    var body: some View {
        ZStack {
            Theme.VM.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                console
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    keyCluster
                }
                .padding(.trailing, 18)
                .padding(.bottom, 24)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { engine.start() }
        .onDisappear { engine.shutdown() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(engine.running ? Theme.VM.accent : Theme.VM.textFaint)
                .frame(width: 6, height: 6)
            Text(engine.stage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.VM.textFaint)
            Spacer()
            glassIcon(showLog ? "text.alignleft" : "text.alignleft", active: showLog) {
                withAnimation(.easeOut(duration: 0.2)) { showLog.toggle() }
            }
            glassIcon("xmark", active: false) {
                engine.shutdown()
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Console

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(engine.lines) { line in
                        Text(line.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 140)
            }
            .opacity(showLog ? 1 : 0)
            .onChange(of: engine.lines.count) { _ in
                if let last = engine.lines.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Floating key cluster (collapsed by default)

    @ViewBuilder
    private var keyCluster: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                clusterBody
            }
        } else {
            clusterBody
        }
    }

    private var clusterBody: some View {
        VStack(spacing: 10) {
            if keysExpanded {
                keyButton("speaker.plus.fill", "音量加") { press(.volumeUp) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                keyButton("speaker.minus.fill", "音量减") { press(.volumeDown) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                keyButton("house.fill", "Home") { press(.home) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                keyButton("power", "电源") { press(.power) }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            keyButton(keysExpanded ? "xmark" : "circle.grid.cross.fill",
                      keysExpanded ? "收起按键" : "展开按键") {
                withAnimation(.easeOut(duration: 0.24)) { keysExpanded.toggle() }
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ icon: String, _ label: String,
                           action: @escaping () -> Void) -> some View {
        let base = Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.VM.text)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)

        if #available(iOS 26.0, *) {
            base.glassEffect(.regular.interactive(), in: .circle)
        } else {
            base.background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Theme.VM.keyStroke, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func glassIcon(_ icon: String, active: Bool,
                           action: @escaping () -> Void) -> some View {
        let base = Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(active ? Theme.VM.accent : Theme.VM.textDim)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)

        if #available(iOS 26.0, *) {
            base.glassEffect(.regular.interactive(), in: .circle)
        } else {
            base.background(.ultraThinMaterial, in: Circle())
        }
    }

    private enum GuestKey { case volumeUp, volumeDown, home, power }

    private func press(_ key: GuestKey) {
        let name: String
        switch key {
        case .volumeUp:   name = "volume_up"
        case .volumeDown: name = "volume_down"
        case .home:       name = "home"
        case .power:      name = "power"
        }
        engine.noteKey(name)
    }

    private func color(for kind: BootEngine.Line.Kind) -> Color {
        switch kind {
        case .ok:    return Theme.VM.ok
        case .warn:  return Theme.VM.warn
        case .error: return Theme.VM.danger
        case .guest: return Theme.VM.accent
        default:     return Theme.VM.textDim
        }
    }
}
