import Foundation

struct AnthropicClient {
    static let model = "claude-sonnet-4-6"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let systemPrompt = """
    You are an AI paste assistant. The user has copied content (Image 1) and wants to paste relevant data into a destination text input on their screen (Image 2). The destination input field is marked with a bright red rectangle.

    Your job: decide what text to put into the marked field. You may:
    - Extract a strict substring from Image 1.
    - Transform Image 1's content: strip filler words, restructure as a list, normalize formatting, summarize, etc., to fit what the destination field is asking for.

    Look at labels, placeholder text, surrounding UI in Image 2 to infer the field's expected format (e.g., comma-separated list, single name, full address, date in MM/DD/YYYY).

    Output ONLY the exact text to paste. No preamble. No explanation. No surrounding quotes. No markdown fences. No trailing newline. If the answer is a list, format it the way the field expects.

    If you genuinely cannot determine what to paste, output exactly: <<NO_PASTE>>
    """

    let apiKey: String

    func paste(copyPng: Data, destPng: Data) async throws -> String {
        var req = URLRequest(url: AnthropicClient.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 25

        let body: [String: Any] = [
            "model": AnthropicClient.model,
            "max_tokens": 1024,
            "system": AnthropicClient.systemPrompt,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": copyPng.base64EncodedString()
                        ] as [String: Any]
                    ] as [String: Any],
                    ["type": "text", "text": "Image 1 = copied content."],
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": destPng.base64EncodedString()
                        ] as [String: Any]
                    ] as [String: Any],
                    ["type": "text", "text": "Image 2 = paste destination (red rectangle marks the target input field)."]
                ]
            ]]
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "ai-cpb", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response."])
        }
        if http.statusCode < 200 || http.statusCode >= 300 {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "ai-cpb", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else {
            throw NSError(domain: "ai-cpb", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape."])
        }

        // Find the first text block.
        for block in content {
            if (block["type"] as? String) == "text",
               let text = block["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw NSError(domain: "ai-cpb", code: -3,
                      userInfo: [NSLocalizedDescriptionKey: "No text content in response."])
    }
}
