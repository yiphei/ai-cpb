import Foundation

struct AnthropicClient: LLMClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    let apiKey: String
    let model: String  = "claude-sonnet-4-6"
    let system: String = "anthropic"

    func sendRequest(systemPrompt: String,
                     copyPngs: [Data],
                     destPng: Data,
                     trailingUserText: String?)
        async throws -> LLMResponse
    {
        var req = URLRequest(url: AnthropicClient.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        var userContent: [[String: Any]] = []
        for (idx, png) in copyPngs.enumerated() {
            userContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": png.base64EncodedString()
                ] as [String: Any]
            ] as [String: Any])
            userContent.append(["type": "text", "text": "Image \(idx + 1) = copied content #\(idx + 1)."])
        }
        let destIndex = copyPngs.count + 1
        userContent.append([
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/png",
                "data": destPng.base64EncodedString()
            ] as [String: Any]
        ] as [String: Any])
        userContent.append(["type": "text", "text": "Image \(destIndex) = paste destination (red rectangle marks the target input field)."])

        if let trailing = trailingUserText, !trailing.isEmpty {
            userContent.append(["type": "text", "text": trailing])
        }

        // Adaptive extended thinking: model uses up to budget_tokens of thinking and stops
        // when done. max_tokens must exceed budget_tokens; the difference is the cap on the
        // visible response text (8192 here matches OpenRouterClient's max_tokens).
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16384,
            "thinking": [
                "type": "enabled",
                "budget_tokens": 8192
            ] as [String: Any],
            "system": systemPrompt,
            "messages": [
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
            let blocks = root["content"] as? [[String: Any]]
        else {
            throw NSError(domain: "copybara", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape."])
        }

        let textParts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        let combinedText = textParts.joined()
        guard !combinedText.isEmpty else {
            throw NSError(domain: "copybara", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Anthropic response had no text block."])
        }

        let thinkingParts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "thinking" else { return nil }
            return block["thinking"] as? String
        }
        let reasoning: String? = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n\n")

        let usage = root["usage"] as? [String: Any]
        let inT = usage?["input_tokens"] as? Int
        let outT = usage?["output_tokens"] as? Int

        return (combinedText.trimmingCharacters(in: .whitespacesAndNewlines), reasoning, inT, outT, http.statusCode)
    }
}
