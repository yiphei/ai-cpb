import Foundation

struct LogfireConfig {
    static let tracesEndpoint = "https://logfire-us.pydantic.dev/v1/traces"
    let writeToken: String
}

final class Config {
    static let shared = Config()

    static let didChangeNotification = Notification.Name("aicpb.Config.didChange")

    static let configDirURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/ai-cpb", isDirectory: true)
    }()

    static let configFileURL: URL = configDirURL.appendingPathComponent("config.json")

    static let providerDefaultsKey = "aicpb.provider"

    private(set) var provider: LLMProvider = .openRouter
    private(set) var apiKey: String?

    let logfire: LogfireConfig?

    private init() {
        if let t = LogfireBuild.token, !t.isEmpty {
            self.logfire = LogfireConfig(writeToken: t)
        } else {
            self.logfire = nil
        }
    }

    func load() {
        provider = UserDefaults.standard.string(forKey: Config.providerDefaultsKey)
            .flatMap(LLMProvider.init(rawValue:)) ?? .openRouter

        apiKey = Keychain.readString(account: provider.keychainAccount)
            .flatMap { $0.isEmpty ? nil : $0 }

        guard let data = try? Data(contentsOf: Config.configFileURL),
              var jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if provider == .openRouter, apiKey == nil,
           let legacy = (jsonObject["openrouter_api_key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacy.isEmpty {
            do {
                try Keychain.writeString(legacy, account: Keychain.openRouterAccount)
                apiKey = legacy
                NSLog("ai-cpb: migrated legacy api key from config.json into Keychain")
            } catch {
                NSLog("ai-cpb: legacy api key migration FAILED: \(error)")
            }
        }

        let hadLegacy =
            jsonObject["openrouter_api_key"] != nil ||
            jsonObject["logfire_write_token"] != nil
        jsonObject.removeValue(forKey: "openrouter_api_key")
        jsonObject.removeValue(forKey: "logfire_write_token")
        if hadLegacy {
            Self.writeJSON(jsonObject)
        }
    }

    @discardableResult
    func setAPIKey(_ key: String?, for newProvider: LLMProvider) -> Result<Void, Error> {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            for p in LLMProvider.allCases where p != newProvider {
                try Keychain.delete(account: p.keychainAccount)
            }
            if let v = trimmed, !v.isEmpty {
                try Keychain.writeString(v, account: newProvider.keychainAccount)
                apiKey = v
            } else {
                try Keychain.delete(account: newProvider.keychainAccount)
                apiKey = nil
            }
            provider = newProvider
            UserDefaults.standard.set(newProvider.rawValue, forKey: Config.providerDefaultsKey)
        } catch {
            return .failure(error)
        }
        NotificationCenter.default.post(name: Config.didChangeNotification, object: nil)
        return .success(())
    }

    private static func writeJSON(_ obj: [String: Any]) {
        do {
            try FileManager.default.createDirectory(
                at: Config.configDirURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Config.configFileURL, options: .atomic)
        } catch {
            NSLog("ai-cpb: failed to rewrite config.json: \(error)")
        }
    }
}
