import Foundation

struct AnthropicClient {
    static let model = "claude-sonnet-4-6"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let systemPrompt = """
    You are an AI paste assistant. The user has copied context (Image 1) and wants to paste relevant data into a destination text input on their screen (Image 2). The destination input field is marked with a bright red rectangle.

    Your job is to intelligently decide a) what to paste, and b) in what format, based on both the copied context and the destination context. For example, what to paste can be (non-exhaustive list):
    a) a substring of the copied context. E.g. if the copied context is approximately "My name is John Doe", and the destination context is a form and the input field is "Name", the pasted context can be "John Doe"
    b) a transformed text of the copied context. E.g. if the copied context is "I am allergic to onions and also garlic. Oh dont forget tomatoes as well", and the destination context is restaurant reservation and input field is "allergies", the pasted content can be "garlic, onion, and tomato"
    c) a computed value based on the copied context and the destination context. E.g. if the copied context is "i was born in 1998", and the destination context is a form and the input field is "age" and today is 2026, the pasted content can be "28"

    To do this job effectivelly, you need to examine very carefully everything in the copied context and the destination context. For instance, look at labels, placeholder text, and surrounding UI.

    Output ONLY the exact text to paste.

    If you genuinely cannot determine what to paste, output exactly: <<NO_PASTE>>
    """

    let apiKey: String

    func paste(copyPng: Data, destPng: Data) async throws -> String {
        let startTime = Date()
        NSLog("ai-cpb: AnthropicClient.paste() start (lf configured=\(Config.shared.langfuse != nil))")
        var responseText: String? = nil
        var inputTokens: Int? = nil
        var outputTokens: Int? = nil
        var httpStatus: Int? = nil
        var errorMessage: String? = nil

        defer {
            if let lf = Config.shared.langfuse {
                LangfuseLogger.shared.log(
                    LangfuseCallRecord(
                        model: AnthropicClient.model,
                        systemPrompt: AnthropicClient.systemPrompt,
                        copyPng: copyPng,
                        destPng: destPng,
                        startTime: startTime,
                        endTime: Date(),
                        response: responseText,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        httpStatus: httpStatus,
                        errorMessage: errorMessage
                    ),
                    config: lf
                )
            }
        }

        do {
            let text: String
            (text, inputTokens, outputTokens, httpStatus) =
                try await sendRequest(copyPng: copyPng, destPng: destPng)
            responseText = text
            return text
        } catch let err as NSError {
            httpStatus = err.code > 0 ? err.code : httpStatus
            errorMessage = err.localizedDescription
            throw err
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func sendRequest(copyPng: Data, destPng: Data)
        async throws -> (text: String, inputTokens: Int?, outputTokens: Int?, httpStatus: Int)
    {
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

        let usage = root["usage"] as? [String: Any]
        let inT = usage?["input_tokens"] as? Int
        let outT = usage?["output_tokens"] as? Int

        for block in content {
            if (block["type"] as? String) == "text",
               let text = block["text"] as? String {
                return (text.trimmingCharacters(in: .whitespacesAndNewlines), inT, outT, http.statusCode)
            }
        }
        throw NSError(domain: "ai-cpb", code: -3,
                      userInfo: [NSLocalizedDescriptionKey: "No text content in response."])
    }
}
