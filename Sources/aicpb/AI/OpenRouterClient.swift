import Foundation

struct OpenRouterClient {
    static let model = "anthropic/claude-sonnet-4.6"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static func systemPrompt(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        let nowString = formatter.string(from: now)
        return """
        The current local datetime is \(nowString).

        You are an AI paste assistant. The user has copied context (Image 1) and wants to paste relevant data into a destination text input on their screen (Image 2). The destination input field is marked with a bright red rectangle.

        Your job is to intelligently decide a) what to paste, and b) in what format, based on both the copied context and the destination context. For example, what to paste can be (non-exhaustive list):
        a) a substring of the copied context. E.g. if the copied context is approximately "My name is John Doe", and the destination context is a form and the input field is "Name", the pasted context can be "John Doe"
        b) a transformed text of the copied context. E.g. if the copied context is "I am allergic to onions and also garlic. Oh dont forget tomatoes as well", and the destination context is restaurant reservation and input field is "allergies", the pasted content can be "garlic, onion, and tomato"
        c) a computed value based on the copied context and the destination context. E.g. if the copied context is "i was born in 1998", and the destination context is a form and the input field is "age" and today is 2026, the pasted content can be "28"

        To do this job effectivelly, you need to examine very carefully everything in the copied context and the destination context. For instance, look at labels, placeholder text, and surrounding UI.

        Output ONLY the exact text to paste.

        If you genuinely cannot determine what to paste, output exactly: <<NO_PASTE>>
        """
    }

    let apiKey: String

    func paste(copyPng: Data, destPng: Data) async throws -> String {
        let startTime = Date()
        let systemPrompt = OpenRouterClient.systemPrompt(now: startTime)
        NSLog("ai-cpb: OpenRouterClient.paste() start (logfire configured=\(Config.shared.logfire != nil))")
        var responseText: String? = nil
        var inputTokens: Int? = nil
        var outputTokens: Int? = nil
        var httpStatus: Int? = nil
        var errorMessage: String? = nil

        defer {
            if let lf = Config.shared.logfire {
                LogfireLogger.shared.log(
                    LogfireCallRecord(
                        model: OpenRouterClient.model,
                        systemPrompt: systemPrompt,
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
                try await sendRequest(systemPrompt: systemPrompt, copyPng: copyPng, destPng: destPng)
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

    private func sendRequest(systemPrompt: String, copyPng: Data, destPng: Data)
        async throws -> (text: String, inputTokens: Int?, outputTokens: Int?, httpStatus: Int)
    {
        var req = URLRequest(url: OpenRouterClient.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://github.com/yiphei/ai-cpb", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("ai-cpb", forHTTPHeaderField: "X-Title")
        req.timeoutInterval = 25

        let copyDataUri = "data:image/png;base64,\(copyPng.base64EncodedString())"
        let destDataUri = "data:image/png;base64,\(destPng.base64EncodedString())"

        let userContent: [[String: Any]] = [
            ["type": "image_url", "image_url": ["url": copyDataUri] as [String: Any]] as [String: Any],
            ["type": "text", "text": "Image 1 = copied content."],
            ["type": "image_url", "image_url": ["url": destDataUri] as [String: Any]] as [String: Any],
            ["type": "text", "text": "Image 2 = paste destination (red rectangle marks the target input field)."]
        ]

        let body: [String: Any] = [
            "model": OpenRouterClient.model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ]
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
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let text = message["content"] as? String
        else {
            throw NSError(domain: "ai-cpb", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response shape."])
        }

        let usage = root["usage"] as? [String: Any]
        let inT = usage?["prompt_tokens"] as? Int
        let outT = usage?["completion_tokens"] as? Int

        return (text.trimmingCharacters(in: .whitespacesAndNewlines), inT, outT, http.statusCode)
    }
}
