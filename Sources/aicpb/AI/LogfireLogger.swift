import Foundation
import ImageIO

struct LogfireCallRecord {
    let system: String
    let model: String
    let systemPrompt: String
    let copyPngs: [Data]
    let destPng: Data
    let startTime: Date
    let endTime: Date
    let response: String?
    let reasoning: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let httpStatus: Int?
    let errorMessage: String?
}

final class LogfireLogger {
    static let shared = LogfireLogger()

    func log(_ record: LogfireCallRecord, config: LogfireConfig) {
        Task.detached(priority: .utility) { [weak self] in
            await self?.send(record, config: config)
        }
    }

    private func send(_ r: LogfireCallRecord, config: LogfireConfig) async {
        let traceIdHex = LogfireLogger.randomHex(byteCount: 16)
        let spanIdHex = LogfireLogger.randomHex(byteCount: 8)
        let startNanos = LogfireLogger.unixNanos(r.startTime)
        let endNanos = LogfireLogger.unixNanos(r.endTime)

        let spanName = "Chat Completion with '\(r.model)'"

        var userContent: [[String: Any]] = []
        for (idx, png) in r.copyPngs.enumerated() {
            let uri = LogfireLogger.dataUriForLogging(png)
            userContent.append(["type": "image_url", "image_url": ["url": uri]])
            userContent.append(["type": "text", "text": "Image \(idx + 1) = copied content #\(idx + 1)."])
        }
        let destDataUri = LogfireLogger.dataUriForLogging(r.destPng)
        let destIndex = r.copyPngs.count + 1
        userContent.append(["type": "image_url", "image_url": ["url": destDataUri]])
        userContent.append(["type": "text", "text": "Image \(destIndex) = paste destination (red rectangle marks the target input field)."])

        let requestBody: [String: Any] = [
            "messages": [
                ["role": "system", "content": r.systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "model": r.model
        ]
        let requestDataString = LogfireLogger.jsonString(requestBody) ?? "{}"

        var responseDataString: String? = nil
        if let response = r.response {
            var assistantMessage: [String: Any] = ["role": "assistant", "content": response]
            if let reasoning = r.reasoning {
                assistantMessage["reasoning"] = reasoning
            }
            var responseBody: [String: Any] = [
                "message": assistantMessage
            ]
            if let inT = r.inputTokens, let outT = r.outputTokens {
                responseBody["usage"] = [
                    "prompt_tokens": inT,
                    "completion_tokens": outT,
                    "total_tokens": inT + outT
                ]
            }
            responseDataString = LogfireLogger.jsonString(responseBody)
        }

        var attributes: [[String: Any]] = [
            otlpAttr("gen_ai.system", string: r.system),
            otlpAttr("gen_ai.request.model", string: r.model),
            otlpAttr("gen_ai.response.model", string: r.model),
            otlpAttr("request_data", string: requestDataString),
            otlpAttr("async", bool: false),
            otlpAttr("logfire.span_type", string: "span"),
            otlpAttr("logfire.msg_template", string: "Chat Completion with {request_data[model]!r}"),
            otlpAttr("logfire.msg", string: spanName)
        ]
        if let inT = r.inputTokens {
            attributes.append(otlpAttr("gen_ai.usage.input_tokens", int: inT))
        }
        if let outT = r.outputTokens {
            attributes.append(otlpAttr("gen_ai.usage.output_tokens", int: outT))
        }
        if let responseData = responseDataString {
            attributes.append(otlpAttr("response_data", string: responseData))
        }
        if let status = r.httpStatus {
            attributes.append(otlpAttr("http.status_code", int: status))
        }

        var span: [String: Any] = [
            "traceId": traceIdHex,
            "spanId": spanIdHex,
            "name": spanName,
            "kind": 3,
            "startTimeUnixNano": String(startNanos),
            "endTimeUnixNano": String(endNanos),
            "attributes": attributes
        ]
        if let err = r.errorMessage {
            span["status"] = ["code": 2, "message": err]
        }

        let envelope: [String: Any] = [
            "resourceSpans": [[
                "resource": [
                    "attributes": [
                        otlpAttr("service.name", string: "ai-cpb")
                    ]
                ],
                "scopeSpans": [[
                    "scope": ["name": "ai-cpb"],
                    "spans": [span]
                ]]
            ]]
        ]

        guard let url = URL(string: LogfireConfig.tracesEndpoint) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.writeToken, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: envelope)

        NSLog("ai-cpb: Logfire POST → \(url.absoluteString) (traceId=\(traceIdHex))")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            NSLog("ai-cpb: Logfire POST ← HTTP \(status): \(preview)")
        } catch {
            NSLog("ai-cpb: Logfire POST failed: \(error.localizedDescription)")
        }
    }

    private func otlpAttr(_ key: String, string value: String) -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }

    private func otlpAttr(_ key: String, int value: Int) -> [String: Any] {
        ["key": key, "value": ["intValue": String(value)]]
    }

    private func otlpAttr(_ key: String, bool value: Bool) -> [String: Any] {
        ["key": key, "value": ["boolValue": value]]
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func unixNanos(_ date: Date) -> UInt64 {
        let secs = date.timeIntervalSince1970
        return UInt64(secs * 1_000_000_000)
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Logfire enforces a per-attribute size cap on string values inside JSON-encoded
    // attributes (request_data), so full-resolution screenshots get truncated and
    // their data URIs become unrenderable. Downscale + JPEG-compress for the log
    // payload only; the LLM still receives the original PNG via OpenRouterClient.
    private static func dataUriForLogging(_ png: Data) -> String {
        if let jpeg = downscaledJpeg(png, maxDimension: 1280, quality: 0.6) {
            return "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private static func downscaledJpeg(_ png: Data, maxDimension: Int, quality: Double) -> Data? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        let destOpts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, destOpts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
