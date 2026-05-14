import Foundation

final class Config {
    static let shared = Config()

    static let configDirURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ai-cpb", isDirectory: true)
    }()

    static let configFileURL: URL = configDirURL.appendingPathComponent("config.json")

    private(set) var apiKey: String?

    func load() {
        apiKey = nil
        guard let data = try? Data(contentsOf: Config.configFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["anthropic_api_key"] as? String,
              !key.isEmpty
        else { return }
        apiKey = key
    }
}
