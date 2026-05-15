import Foundation

struct LangfuseConfig {
    static let host = "https://us.cloud.langfuse.com"
    let publicKey: String
    let secretKey: String
}

final class Config {
    static let shared = Config()

    static let configDirURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ai-cpb", isDirectory: true)
    }()

    static let configFileURL: URL = configDirURL.appendingPathComponent("config.json")

    private(set) var apiKey: String?
    private(set) var langfuse: LangfuseConfig?

    func load() {
        apiKey = nil
        langfuse = nil
        guard let data = try? Data(contentsOf: Config.configFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let key = obj["openrouter_api_key"] as? String, !key.isEmpty {
            apiKey = key
        }
        if let pk = obj["langfuse_public_key"] as? String, !pk.isEmpty,
           let sk = obj["langfuse_secret_key"] as? String, !sk.isEmpty {
            langfuse = LangfuseConfig(publicKey: pk, secretKey: sk)
        }
    }
}
