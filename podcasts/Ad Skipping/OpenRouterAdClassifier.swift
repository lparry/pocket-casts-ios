import Foundation

/// Asks a model on OpenRouter, with the listener's own key, to find the ads in a transcript
struct OpenRouterAdClassifier: AdClassifier {
    static let defaultModel = "anthropic/claude-sonnet-5.5"
    static let identifierPrefix = "openrouter:"

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    let apiKey: String
    let model: String
    var session: URLSession = .shared

    var identifier: String {
        Self.identifierPrefix + model
    }

    func adSpans(in transcript: [TranscriptSegment], context: AdClassificationContext) async throws -> [AdSpan] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Pocket Casts Ad Skipping", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(model: model, transcript: transcript, context: context))

        let (data, urlResponse) = try await session.data(for: request)
        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message ?? "HTTP \(statusCode)"
            throw AdSkippingError.classifierFailed("OpenRouter error: \(message)")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)

        // OpenRouter can return 200 with an error from the upstream provider
        if let error = response.error {
            throw AdSkippingError.classifierFailed("OpenRouter error: \(error.message)")
        }

        guard let choice = response.choices?.first else {
            throw AdSkippingError.classifierFailed("OpenRouter returned no choices")
        }

        if choice.finishReason == "length" {
            throw AdSkippingError.classifierFailed("The model's response was cut off")
        }

        guard let content = choice.message.content, let contentData = content.data(using: .utf8) else {
            throw AdSkippingError.classifierFailed(choice.message.refusal ?? "The model's response had no content")
        }

        let output = try JSONDecoder().decode(ClassifierOutput.self, from: contentData)
        let spans = output.ads.map { AdSpan(start: $0.start, end: $0.end, kind: $0.kind, sponsor: $0.sponsor) }
        return cleanedUp(spans, duration: context.duration)
    }

    static func requestBody(model: String, transcript: [TranscriptSegment], context: AdClassificationContext) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
            "messages": [
                ["role": "system", "content": AdClassifierPrompt.instructions],
                ["role": "user", "content": AdClassifierPrompt.prompt(transcript: transcript, context: context)]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "ad_spans",
                    "strict": true,
                    "schema": outputSchema
                ]
            ],
            // Only route to providers that honour the schema
            "provider": ["require_parameters": true]
        ]
    }

    private static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "ads": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "number"],
                        "end": ["type": "number"],
                        "kind": ["type": "string", "enum": AdSpan.Kind.allCases.map(\.rawValue)],
                        "sponsor": ["type": "string"]
                    ],
                    "required": ["start", "end", "kind", "sponsor"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["ads"],
        "additionalProperties": false
    ]

    // MARK: - Response

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let refusal: String?
            }

            let message: Message
            let finishReason: String?
        }

        let choices: [Choice]?
        let error: ErrorResponse.Detail?
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }

        let error: Detail
    }

    private struct ClassifierOutput: Decodable {
        struct Ad: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let kind: AdSpan.Kind
            let sponsor: String
        }

        let ads: [Ad]
    }
}
