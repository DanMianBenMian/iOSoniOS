import SwiftUI

/// The running-VM surface: pure black, no chrome from the host app, a floating
/// key strip, and the guest's own console output.
struct VMView: View {
    let config: VMConfig
    @StateObject private var engine: BootEngine
    @Environment(\.dismiss) private var dismiss

    @State private var keysVisible = true
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

            // Floating keys, bottom-right, the way a VM app usually places them.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if keysVisible { keyPad }
                }
                .padding(.trailing, 18)
                .padding(.bottom, 26)
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
                .frame(width: 7, height: 7)
            Text(engine.stage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.VM.textDim)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showLog.toggle() }
            } label: {
                Image(systemName: showLog ? "text.alignleft" : "text.alignleft")
                    .font(.system(size: 13))
                    .foregroundColor(showLog ? Theme.VM.accent : Theme.VM.textFaint)
            }
            Button {
                withAnimation(.easeOut(duration: 0.2)) { keysVisible.toggle() }
            } label: {
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: 13))
                    .foregroundColor(keysVisible ? Theme.VM.accent : Theme.VM.textFaint)
            }
            Button {
                engine.shutdown()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.VM.textDim)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
                .padding(.bottom, 120)
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

    // MARK: - Floating keys

    private var keyPad: some View {
        VStack(spacing: 8) {
            keyButton("speaker.plus.fill", "音量加") { press(.volumeUp) }
            keyButton("speaker.minus.fill", "音量减") { press(.volumeDown) }
            keyButton("house.fill", "Home") { press(.home) }
            keyButton("power", "电源") { press(.power) }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.VM.keyStroke, lineWidth: 0.5)
        )
    }

    private func keyButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.VM.text)
                .frame(width: 44, height: 44)
                .background(Theme.VM.keyFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private enum GuestKey { case volumeUp, volumeDown, home, power }

    private func press(_ key: GuestKey) {
        // Guest input is not wired to a running kernel yet; echo it so the log
        // shows the plumbing is live.
        let name: String
        switch key {
        case .volumeUp:   name = "volume_up"
        case .volumeDown: name = "volume_down"
        case .home:       name = "home"
        case .power:      name = "power"
        }
        RyLog.log("vm", "key \(name)", level: .guest)
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
