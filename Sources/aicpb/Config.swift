import Foundation

struct LogfireConfig {
    static let tracesEndpoint = "https://logfire-us.pydantic.dev/v1/traces"
    let writeToken: String
}

final class Config {
    static let shared = Config()

    static let configDirURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ai-cpb", isDirectory: true)
    }()

    static let configFileURL: URL = configDirURL.appendingPathComponent("config.json")

    private(set) var apiKey: String?
    private(set) var logfire: LogfireConfig?

    func load() {
        apiKey = nil
        logfire = nil
        guard let data = try? Data(contentsOf: Config.configFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let key = obj["openrouter_api_key"] as? String, !key.isEmpty {
            apiKey = key
        }
        if let token = obj["logfire_write_token"] as? String, !token.isEmpty {
            logfire = LogfireConfig(writeToken: token)
        }
    }
}
