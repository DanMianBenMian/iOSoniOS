import SwiftUI

struct ConfigView: View {
    @State private var config = VMConfig.defaults
    let onCreate: (VMConfig) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("虚拟机") {
                    TextField("名称", text: $config.name)
                }

                Section("硬件") {
                    Stepper("内存：\(config.ramMB) MB", value: $config.ramMB, in: 512...6144, step: 512)
                    Stepper("CPU 核心：\(config.cpuCount)", value: $config.cpuCount, in: 1...4)
                }

                Section("显示") {
                    Picker("分辨率", selection: Binding(
                        get: { Resolution(width: config.width, height: config.height) },
                        set: { config.width = $0.width; config.height = $0.height }
                    )) {
                        ForEach(Resolution.all) { r in
                            Text("\(r.width) × \(r.height)").tag(r)
                        }
                    }
                    Toggle("启用图形显示", isOn: $config.enableDisplay)
                }

                Section("高级") {
                    Toggle("启用 JIT", isOn: $config.enableJIT)
                    TextField("启动参数", text: $config.bootArgs)
                        .font(.system(.body, design: .monospaced))
                }

                Section {
                    Button("创建虚拟机") {
                        config.save()
                        onCreate(config)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("创建后不会立即运行。进入主界面后点 Start 才开始。参数随时可以改。")
                }
            }
            .navigationTitle("配置虚拟机")
        }
    }
}

struct Resolution: Hashable, Identifiable {
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }

    static let all = [
        Resolution(width: 1170, height: 2532),
        Resolution(width: 834, height: 1194),
        Resolution(width: 1080, height: 1920),
        Resolution(width: 768, height: 1024),
    ]
}
