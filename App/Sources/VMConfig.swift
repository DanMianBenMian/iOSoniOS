import Foundation

/// User-tunable virtual machine parameters, persisted between launches.
struct VMConfig: Codable {
    var name: String = "我的 iOS"
    var ramMB: Int = 2048
    var cpuCount: Int = 2
    var width: Int = 1170
    var height: Int = 2532
    var enableJIT: Bool = true
    var enableDisplay: Bool = true
    var bootArgs: String = "-v"

    static let defaults = VMConfig()

    static func load() -> VMConfig? {
        guard let data = UserDefaults.standard.data(forKey: "vm_config") else { return nil }
        return try? JSONDecoder().decode(VMConfig.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "vm_config")
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: "vm_config")
    }
}
