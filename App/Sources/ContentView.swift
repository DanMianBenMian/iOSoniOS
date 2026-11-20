import SwiftUI

struct ContentView: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            HomeView().tabItem { Label("VM", systemImage: "square.stack.3d.up") }.tag(0)
            LogView().tabItem { Label("Log", systemImage: "doc.text.magnifyingglass") }.tag(1)
            AboutView().tabItem { Label("Info", systemImage: "info.circle") }.tag(2)
        }
    }
}

struct HomeView: View {
    @State private var running = false
    @State private var assetStatus = "checking…"
    @State private var jitStatus = "not probed"

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                Text("iOS on iOS").font(.title2.weight(.semibold))
                Text("User-mode full-hardware emulation of XNU").font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    StatusRow(title: "Assets", value: assetStatus)
                    StatusRow(title: "JIT", value: jitStatus)
                    StatusRow(title: "Stage", value: "P1 — engine self-test")
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Button {
                    runSelfTest()
                } label: {
                    Label("Run engine self-test", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)

                Spacer()
            }
            .padding()
            .navigationTitle("iOSoniOS")
            .onAppear { probeAssets() }
        }
    }

    private func probeAssets() {
        let fm = FileManager.default
        let docs = RyLog.documentsURL
        let needed = ["bootkc", "dtree", "ramdisk.dmg", "trustcache", "nvram.bin"]
        let found = needed.filter { fm.fileExists(atPath: docs.appendingPathComponent($0).path) }
        assetStatus = "\(found.count)/\(needed.count) in Documents"
        RyLog.log("assets", "found \(found.count)/\(needed.count): \(found.joined(separator: ", "))")
    }

    private func runSelfTest() {
        running = true
        RyLog.log("selftest", "begin", level: .info)
        RyLog.log("selftest", "device=\(ProcessInfo.processInfo.machineName) pages=16384")
        let result = RyEngineSelfTest.run()
        jitStatus = result.jitOK ? "map+write+exec OK" : "FAILED: \(result.detail)"
        RyLog.log("selftest", "JIT result: \(result.jitOK ? "OK" : "FAIL") - \(result.detail)",
                  level: result.jitOK ? .info : .error)
        RyLog.log("selftest", "MMU model: 16KB guest pages map 1:1 to host", level: .info)
        RyLog.log("selftest", "complete", level: .info)
        running = false
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Attack plan").font(.title3.weight(.semibold))
                Text("""
                Goal: boot a real iOS XNU kernelcache inside an iPad app by emulating
                just enough hardware in user space, with a forged Apple device tree.

                Stage 0 (done): extract A14 27b2 kernelcache + J272AP DeviceTree,
                port darwin-vm's ADT fixup, verify byte-exact round trip.

                Stage 1 (here): bring up the arm64 JIT + software MMU engine inside
                the app, confirm MAP_JIT / debugger attach, verify live logging.

                Stage 2: feed kernelcache + fixed ADT, chase first serial output.
                Stage 3: root shell. Stage 4+: display, touch, GUI.

                All logs auto-flush to Documents/iosonios.log on every line.
                """)
                .font(.system(.body, design: .monospaced))

                Text("References").font(.title3.weight(.semibold))
                Link("darwin-vm", destination: URL(string: "https://github.com/jprx/darwin-vm")!)
                Link("Henge", destination: URL(string: "https://github.com/Leviidev/Henge")!)
                Link("UniXNU", destination: URL(string: "https://github.com/UniXNU/UniXNU")!)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Info")
    }
}

#Preview { ContentView() }
