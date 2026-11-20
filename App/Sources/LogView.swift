import SwiftUI
import UIKit

struct LogView: View {
    @State private var entries: [RyLog.Entry] = []
    @State private var levelFilter: RyLog.Level = .trace
    @State private var showShare = false

    private var filtered: [RyLog.Entry] {
        let order = RyLog.Level.allCases
        let threshold = order.firstIndex(of: levelFilter) ?? 0
        return entries.filter { e in
            let idx = order.firstIndex { $0.rawValue == e.level } ?? 0
            return idx >= threshold
        }
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List {
                        ForEach(filtered) { e in
                            HStack(alignment: .top, spacing: 6) {
                                Text(e.time)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.textFaint)
                                Text(e.level.uppercased())
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(color(for: e.level))
                                    .frame(width: 42, alignment: .leading)
                                Text("[\(e.tag)] \(e.message)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.textMuted)
                                    .textSelection(.enabled)
                            }
                            .id(e.id)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: filtered.count) { _ in
                        if let last = filtered.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Picker("级别", selection: $levelFilter) {
                    ForEach(RyLog.Level.allCases, id: \.self) { l in Text(l.rawValue).tag(l) }
                }
                .pickerStyle(.segmented)
                .padding(10)
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showShare = true } label: {
                    Image(systemName: "square.and.arrow.up").foregroundColor(Theme.textMuted)
                }
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [RyLog.logFileURL]) }
        .task {
            while !Task.isCancelled {
                entries = RyLog.recent(600)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "error": return Theme.logError
        case "warn": return Theme.logWarn
        case "guest": return Theme.logGuest
        default: return Theme.textFaint
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
