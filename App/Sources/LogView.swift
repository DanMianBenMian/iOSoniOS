import SwiftUI
import UIKit

struct LogView: View {
    @State private var entries: [RyLog.Entry] = []
    @State private var levelFilter: RyLog.Level = .trace
    @State private var autoScroll = true
    @State private var search = ""
    @State private var showShare = false

    private var filtered: [RyLog.Entry] {
        let order = RyLog.Level.allCases
        let threshold = order.firstIndex(of: levelFilter) ?? 0
        return entries.filter { e in
            let idx = order.firstIndex { $0.rawValue == e.level } ?? 0
            guard idx >= threshold else { return false }
            if search.isEmpty { return true }
            return e.message.localizedCaseInsensitiveContains(search)
                || e.tag.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List {
                        ForEach(filtered) { e in
                            HStack(alignment: .top, spacing: 6) {
                                Text(e.time)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(e.level.uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(color(for: e.level))
                                    .frame(width: 42, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("[\(e.tag)]")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                    Text(e.message)
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .id(e.id)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: filtered.count) { _ in
                        if autoScroll, let last = filtered.last {
                            withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                HStack {
                    Picker("Level", selection: $levelFilter) {
                        ForEach(RyLog.Level.allCases, id: \.self) { l in
                            Text(l.rawValue).tag(l)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .font(.caption)
                }
                .padding(8)
            }
            .searchable(text: $search, prompt: "Filter log")
            .navigationTitle("Engine log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showShare = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [RyLog.logFileURL])
            }
            .task {
                // Refresh while the view is up; the log writer itself is live.
                while !Task.isCancelled {
                    entries = RyLog.recent(1000)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "error": return .red
        case "warn": return .orange
        case "guest": return .purple
        case "trace": return .secondary
        default: return .primary
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
