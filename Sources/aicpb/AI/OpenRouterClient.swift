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

        You are an AI paste assistant. The user has copied one or more contexts (Images 1..N) and wants to paste relevant data into a destination text input on their screen (the LAST image, Image N+1). The destination input field is marked with a bright red rectangle.

        The copied contexts are independent snapshots — they may be related or unrelated. Consider all of them when deciding what to paste; pull from whichever copy (or combination of copies) best fits the destination field.

        Your job is to intelligently decide a) what to paste, and b) in what format, based on both the copied context(s) and the destination context. For example, what to paste can be (non-exhaustive list):
        a) a substring of the copied context. E.g. if the copied context is approximately "My name is John Doe", and the destination context is a form and the input field is "Name", the pasted context can be "John Doe"
        b) a transformed text of the copied context. E.g. if the copied context is "I am allergic to onions and also garlic. Oh dont forget tomatoes as well", and the destination context is restaurant reservation and input field is "allergies", the pasted content can be "garlic, onion, and tomato"
        c) a computed value based on the copied context and the destination context. E.g. if the copied context is "i was born in 1998", and the destination context is a form and the input field is "age" and today is 2026, the pasted content can be "28"

        To do this job effectivelly, you need to examine very carefully everything in the copied context and the destination context. For instance, look at labels, placeholder text, and surrounding UI.

        Output ONLY the exact text to paste. You must exclude any internal work like calculations, reasoning, etc. from the output.

        If you genuinely cannot determine what to paste, output exactly: <<NO_PASTE>>
        """
    }

    let apiKey: String

    func paste(copyPngs: [Data], destPng: Data) async throws -> String {
        let startTime = Date()
        let systemPrompt = OpenRouterClient.systemPrompt(now: startTime)
        NSLog("ai-cpb: OpenRouterClient.paste() start (logfire configured=\(Config.shared.logfire != nil))")
        var responseText: String? = nil
        var reasoningText: String? = nil
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
                        copyPngs: copyPngs,
                        destPng: destPng,
                        startTime: startTime,
                        endTime: Date(),
                        response: responseText,
                        reasoning: reasoningText,
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
            (text, reasoningText, inputTokens, outputTokens, httpStatus) =
                try await sendRequest(systemPrompt: systemPrompt, copyPngs: copyPngs, destPng: destPng)
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

    private func sendRequest(systemPrompt: String, copyPngs: [Data], destPng: Data)
        async throws -> (text: String, reasoning: String?, inputTokens: Int?, outputTokens: Int?, httpStatus: Int)
    {
        var req = URLRequest(url: OpenRouterClient.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://github.com/yiphei/ai-cpb", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("ai-cpb", forHTTPHeaderField: "X-Title")
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
            "model": OpenRouterClient.model,
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
