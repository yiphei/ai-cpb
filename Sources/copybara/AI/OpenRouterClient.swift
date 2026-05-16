import Foundation

struct OpenRouterClient: LLMClient {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    let apiKey: String
    let model: String  = "anthropic/claude-sonnet-4.6"
    let system: String = "openai"

    func sendRequest(systemPrompt: String, copyPngs: [Data], destPng: Data)
        async throws -> LLMResponse
    {
        var req = URLRequest(url: OpenRouterClient.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://github.com/yiphei/ai-cpb", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("copybara", forHTTPHeaderField: "X-Title")
        req.timeoutInterval = 60

        var userContent: [[String: Any]] = []
        for (idx, png) in copyPngs.enumerated() {
            let uri = "data:image/png;base64,\(png.base64EncodedString())"
            userContent.append(["type": "image_url", "image_url": ["url": uri] as [String: Any]] as [String: Any])
            userContent.append(["type": "text", "text": "Image \(idx + 1) = copied content #\(idx + 1)."])
        }
        let destDataUri = "data:image/png;base64,\(destPng.base64EncodedString())"
        let destIndex = copyPngs.count + 1
        userContent.append(["type": "image_url", "image_url": ["url": destDataUri] as [String: Any]] as [String: Any])
        userContent.append(["type": "text", "text": "Image \(destIndex) = paste destination (red rectangle marks the target input field)."])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "reasoning": ["enabled": true],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "copybara", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response."])
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "copybara", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let text = message["content"] as? String
        else {
            throw NSError(domain: "copybara", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape."])
        }

        let reasoning: String? = {
            if let s = message["reasoning"] as? String, !s.isEmpty { return s }
            if let details = message["reasoning_details"] as? [[String: Any]] {
                let parts = details.compactMap {
                    ($0["text"] as? String) ?? ($0["data"] as? String) ?? ($0["summary"] as? String)
                }
                return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
            }
            return nil
        }()

        let usage = root["usage"] as? [String: Any]
        let inT = usage?["prompt_tokens"] as? Int
        let outT = usage?["completion_tokens"] as? Int

        return (text.trimmingCharacters(in: .whitespacesAndNewlines), reasoning, inT, outT, http.statusCode)
    }
}
