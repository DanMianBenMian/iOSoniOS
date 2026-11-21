import SwiftUI

/// The running-VM surface: pure black, minimal chrome, a collapsible floating
/// key cluster in Liquid Glass, a live boot-progress panel at the top, and the
/// guest's own console output below.
struct VMView: View {
    let config: VMConfig
    @StateObject private var engine: BootEngine
    @Environment(\.dismiss) private var dismiss

    @State private var keysExpanded = false      // collapsed by default
    @State private var viewMode: ViewMode = .screen   // guest screen is the star
    @State private var rawEntries: [RyLog.Entry] = []
    private enum ViewMode { case screen, console }

    init(config: VMConfig) {
        self.config = config
        _engine = StateObject(wrappedValue: BootEngine(config: config))
    }

    var body: some View {
        ZStack {
            Theme.VM.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                progressPanel
                if let issue = engine.issue { issueCard(issue) }
                if viewMode == .screen {
                    GuestScreenView()
                } else {
                    console
                }
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
        .task {
            while !Task.isCancelled {
                rawEntries = RyLog.recent(1000)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(engine.running ? Theme.VM.accent : Theme.VM.textFaint)
                .frame(width: 6, height: 6)
            Text("iOSoniOS · 虚拟机")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.VM.textDim)
            Spacer()
            glassIcon(viewMode == .screen ? "display" : "text.alignleft",
                      active: true) {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewMode = (viewMode == .screen) ? .console : .screen
                }
            }
            .accessibilityLabel(viewMode == .screen ? "查看日志" : "查看屏幕")
            glassIcon("xmark", active: false) {
                engine.shutdown()
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Live progress panel

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                stageTile
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.stage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.VM.text)
                    Text(progressCaption)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.VM.textDim)
                }
                Spacer(minLength: 8)
                percentLabel
            }

            progressBar

            stepChain
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.VM.panelFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.VM.keyStroke, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    /// Stage icon in a squircle tile, tinted by the current status.
    private var stageTile: some View {
        let current = engine.steps.first { $0.state == .running }
        let icon = current?.icon ?? (engine.progress >= 1 ? "checkmark" : "bolt.fill")
        let color = panelTint
        return RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(color.opacity(0.18))
            .frame(width: 38, height: 38)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(color.opacity(0.35), lineWidth: 0.5)
            )
    }

    private var percentLabel: some View {
        Text(String(format: "%.0f%%", engine.progress * 100))
            .font(.system(size: 22, weight: .medium, design: .monospaced))
            .foregroundColor(panelTint)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: engine.progress)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.VM.keyFill).frame(height: 6)
                Capsule()
                    .fill(panelTint)
                    .frame(width: max(0, geo.size.width * CGFloat(engine.progress)), height: 6)
                    .animation(.easeOut(duration: 0.3), value: engine.progress)
            }
        }
        .frame(height: 6)
    }

    private var stepChain: some View {
        HStack(spacing: 0) {
            ForEach(engine.steps) { step in
                stepChip(step)
                if step.id < engine.steps.count - 1 {
                    Spacer(minLength: 2)
                }
            }
        }
    }

    @ViewBuilder
    private func stepChip(_ step: BootEngine.BootStep) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(stepFill(step.state))
                    .frame(width: 20, height: 20)
                switch step.state {
                case .done:
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black)
                case .failed:
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                case .running:
                    Circle().fill(.white).frame(width: 5, height: 5)
                case .skipped:
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.VM.textFaint)
                case .pending:
                    Circle().fill(Theme.VM.textFaint).frame(width: 5, height: 5)
                }
            }
            Text(step.title)
                .font(.system(size: 8.5))
                .foregroundColor(step.state == .running
                                 ? Theme.VM.text
                                 : (step.state == .pending || step.state == .skipped
                                    ? Theme.VM.textFaint : Theme.VM.textDim))
                .lineLimit(1)
        }
        .frame(minWidth: 34)
    }

    private func stepFill(_ s: BootEngine.BootStep.State) -> Color {
        switch s {
        case .done:     return Theme.VM.ok
        case .failed:   return Theme.VM.danger
        case .running:  return Theme.VM.accent
        case .skipped:  return Theme.VM.keyFill
        case .pending:  return Theme.VM.keyStroke
        }
    }

    private var panelTint: Color {
        if let issue = engine.issue { return issue.fatal ? Theme.VM.danger : Theme.VM.warn }
        if engine.progress >= 1 { return Theme.VM.ok }
        return Theme.VM.accent
    }

    private var progressCaption: String {
        let done = engine.steps.filter { $0.state == .done }.count
        let total = engine.steps.count
        if let issue = engine.issue, issue.fatal {
            return "在第 \(done + 1)/\(total) 步停下"
        }
        return "步骤 \(done)/\(total) · 真实进度"
    }

    // MARK: - Error card

    @ViewBuilder
    private func issueCard(_ issue: BootEngine.BootIssue) -> some View {
        let color = issue.fatal ? Theme.VM.danger : Theme.VM.warn
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.18))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: issue.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(color)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.VM.text)
                Text(issue.detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.VM.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            glassIcon("xmark", active: false) { engine.dismissIssue() }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.30), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.25), value: engine.issue?.id)
    }

    // MARK: - Console

    /// Raw low-level log, byte-for-byte what lands in iosonios.log:
    /// `[time] LEVEL tag: message`. No app-authored Chinese narration.
    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rawEntries) { e in
                        Text("[\(e.time)] \(e.level.uppercased()) \(e.tag): \(e.message)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(rawColor(e.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(e.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 140)
            }
            .onChange(of: rawEntries.count) { _ in
                if let last = rawEntries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func rawColor(_ level: String) -> Color {
        switch level {
        case "error": return Theme.VM.danger
        case "warn":  return Theme.VM.warn
        case "guest": return Theme.VM.accent
        case "info":  return Theme.VM.text
        default:      return Theme.VM.textDim
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
