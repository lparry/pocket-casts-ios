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
        let content = try await complete(Self.requestBody(model: model, transcript: transcript, context: context))
        let output = try JSONDecoder().decode(ClassifierOutput.self, from: content)
        let spans = output.ads.map { AdSpan(start: $0.start, end: $0.end, kind: $0.kind, sponsor: $0.sponsor) }
        return cleanedUp(spans, duration: context.duration)
    }

    func boundaryWordIndices(for requests: [AdBoundaryRequest]) async throws -> [Int?] {
        guard !requests.isEmpty else { return [] }

        let content = try await complete(Self.boundaryRequestBody(model: model, requests: requests))
        let output = try JSONDecoder().decode(BoundaryOutput.self, from: content)

        var indices = [Int?](repeating: nil, count: requests.count)
        for edge in output.edges where indices.indices.contains(edge.id) && edge.wordIndex >= 0 {
            indices[edge.id] = edge.wordIndex
        }
        return indices
    }

    /// Sends a chat completion and returns the model's JSON content
    private func complete(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Pocket Casts Ad Skipping", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, urlResponse) = try await session.data(for: request)
        let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message ?? "HTTP \(statusCode)"
            throw Self.error(message: "OpenRouter error: \(message)", code: statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)

        // OpenRouter can return 200 with an error from the upstream provider
        if let error = response.error {
            throw Self.error(message: "OpenRouter error: \(error.message)", code: error.code)
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

        return contentData
    }

    /// Whether an error with this HTTP status is likely to clear up: a missing or unpaid key, a timeout, rate limiting, or a
    /// problem on OpenRouter's or the provider's side. Anything else, like a transcript too long for the model or a model
    /// that can't follow the schema, fails the same way every time.
    static func isRetryable(statusCode: Int) -> Bool {
        [401, 402, 408, 429].contains(statusCode) || (500..<600).contains(statusCode)
    }

    /// An error without a code is usually the upstream provider failing, so it's treated as temporary
    private static func error(message: String, code: Int?) -> AdSkippingError {
        if let code, !isRetryable(statusCode: code) {
            return .classifierFailed(message)
        }
        return .classifierUnavailable(message)
    }

    static func requestBody(model: String, transcript: [TranscriptSegment], context: AdClassificationContext) -> [String: Any] {
        body(model: model,
             system: AdClassifierPrompt.instructions,
             user: AdClassifierPrompt.prompt(transcript: transcript, context: context),
             schemaName: "ad_spans",
             schema: outputSchema,
             maxTokens: 16000)
    }

    static func boundaryRequestBody(model: String, requests: [AdBoundaryRequest]) -> [String: Any] {
        body(model: model,
             system: AdClassifierPrompt.batchedBoundaryInstructions,
             user: AdClassifierPrompt.boundaryPrompt(for: requests),
             schemaName: "ad_boundaries",
             schema: boundarySchema,
             maxTokens: 16000)
    }

    private static func body(model: String, system: String, user: String, schemaName: String, schema: [String: Any], maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": schemaName,
                    "strict": true,
                    "schema": schema
                ]
            ],
            // Only route to providers that honour the schema
            "provider": ["require_parameters": true]
        ]
    }

    private static let boundarySchema: [String: Any] = [
        "type": "object",
        "properties": [
            "edges": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "word_index": ["type": "integer"]
                    ],
                    "required": ["id", "word_index"],
                    "additionalProperties": false
                ]
            ]
        ],
        "required": ["edges"],
        "additionalProperties": false
    ]

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
            /// Usually the HTTP status, but read leniently so an unexpected value can't hide the message
            let code: Int?

            private enum CodingKeys: String, CodingKey {
                case message
                case code
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                message = try container.decode(String.self, forKey: .message)
                code = try? container.decode(Int.self, forKey: .code)
            }
        }

        let error: Detail
    }

    private struct BoundaryOutput: Decodable {
        struct Edge: Decodable {
            let id: Int
            let wordIndex: Int

            enum CodingKeys: String, CodingKey {
                case id
                case wordIndex = "word_index"
            }
        }

        let edges: [Edge]
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
