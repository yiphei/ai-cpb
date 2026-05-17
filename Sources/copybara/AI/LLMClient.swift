import Foundation

typealias LLMResponse = (
    text: String,
    reasoning: String?,
    inputTokens: Int?,
    outputTokens: Int?,
    httpStatus: Int
)

func llmSystemPrompt(now: Date = Date()) -> String {
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

protocol LLMClient {
    var model: String  { get }
    var system: String { get }

    func sendRequest(systemPrompt: String,
                     copyPngs: [Data],
                     destPng: Data,
                     trailingUserText: String?)
        async throws -> LLMResponse
}

extension LLMClient {
    func paste(copyPngs: [Data],
               destPng: Data,
               trailingUserText: String? = nil,
               parentSpan: LogfirePasteSpan? = nil) async throws -> String {
        let startTime = Date()
        let prompt = llmSystemPrompt(now: startTime)
        NSLog("copybara: \(Self.self).paste() start (logfire configured=\(Config.shared.logfire != nil))")

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
                        system: system,
                        model: model,
                        systemPrompt: prompt,
                        copyPngs: copyPngs,
                        destPng: destPng,
                        startTime: startTime,
                        endTime: Date(),
                        response: responseText,
                        reasoning: reasoningText,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        httpStatus: httpStatus,
                        errorMessage: errorMessage,
                        parentTraceId: parentSpan?.traceId,
                        parentSpanId: parentSpan?.spanId
                    ),
                    config: lf
                )
            }
        }

        do {
            let r = try await sendRequest(systemPrompt: prompt,
                                          copyPngs: copyPngs,
                                          destPng: destPng,
                                          trailingUserText: trailingUserText)
            responseText = r.text
            reasoningText = r.reasoning
            inputTokens = r.inputTokens
            outputTokens = r.outputTokens
            httpStatus = r.httpStatus
            return r.text
        } catch let err as NSError {
            httpStatus = err.code > 0 ? err.code : nil
            errorMessage = err.localizedDescription
            throw err
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
