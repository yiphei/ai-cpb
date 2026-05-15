import Foundation

struct LangfuseCallRecord {
    let model: String
    let systemPrompt: String
    let copyPng: Data
    let destPng: Data
    let startTime: Date
    let endTime: Date
    let response: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let httpStatus: Int?
    let errorMessage: String?
}

final class LangfuseLogger {
    static let shared = LangfuseLogger()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func log(_ record: LangfuseCallRecord, config: LangfuseConfig) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.send(record, config: config)
        }
    }

    private func send(_ r: LangfuseCallRecord, config: LangfuseConfig) async {
        let traceId = UUID().uuidString
        let genId = UUID().uuidString
        let nowISO = LangfuseLogger.iso.string(from: Date())
        let startISO = LangfuseLogger.iso.string(from: r.startTime)
        let endISO = LangfuseLogger.iso.string(from: r.endTime)

        let copyDataUri = "data:image/png;base64,\(r.copyPng.base64EncodedString())"
        let destDataUri = "data:image/png;base64,\(r.destPng.base64EncodedString())"

        let userContent: [[String: Any]] = [
            ["type": "image_url", "image_url": ["url": copyDataUri]],
            ["type": "text", "text": "Image 1 = copied content."],
            ["type": "image_url", "image_url": ["url": destDataUri]],
            ["type": "text", "text": "Image 2 = paste destination (red rectangle marks the target input field)."]
        ]
        let messages: [[String: Any]] = [
            ["role": "system", "content": r.systemPrompt],
            ["role": "user", "content": userContent]
        ]

        var generationBody: [String: Any] = [
            "id": genId,
            "traceId": traceId,
            "name": "openrouter.chat.completions",
            "model": r.model,
            "input": messages,
            "startTime": startISO,
            "endTime": endISO,
            "level": r.errorMessage == nil ? "DEFAULT" : "ERROR"
        ]
        if let response = r.response {
            generationBody["output"] = response
        }
        if let inT = r.inputTokens, let outT = r.outputTokens {
            generationBody["usage"] = [
                "input": inT,
                "output": outT,
                "total": inT + outT,
                "unit": "TOKENS"
            ]
        }
        if let err = r.errorMessage {
            generationBody["statusMessage"] = err
        }

        var traceMetadata: [String: Any] = [:]
        if let status = r.httpStatus { traceMetadata["http_status"] = status }
        if let err = r.errorMessage { traceMetadata["error"] = err }

        var traceBody: [String: Any] = [
            "id": traceId,
            "name": "ai-paste"
        ]
        if let response = r.response { traceBody["output"] = response }
        if !traceMetadata.isEmpty { traceBody["metadata"] = traceMetadata }

        let batch: [[String: Any]] = [
            [
                "id": UUID().uuidString,
                "type": "trace-create",
                "timestamp": nowISO,
                "body": traceBody
            ],
            [
                "id": UUID().uuidString,
                "type": "generation-create",
                "timestamp": nowISO,
                "body": generationBody
            ]
        ]

        guard let url = URL(string: "\(LangfuseConfig.host)/api/public/ingestion") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let creds = "\(config.publicKey):\(config.secretKey)"
        if let b64 = creds.data(using: .utf8)?.base64EncodedString() {
            req.setValue("Basic \(b64)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["batch": batch])

        NSLog("ai-cpb: Langfuse POST → \(url.absoluteString) (traceId=\(traceId))")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            NSLog("ai-cpb: Langfuse POST ← HTTP \(status): \(preview)")
        } catch {
            NSLog("ai-cpb: Langfuse POST failed: \(error.localizedDescription)")
        }
    }
}
