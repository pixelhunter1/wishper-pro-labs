import Foundation

struct OpenAITranslationClient {
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func translate(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        apiKey: String,
        model: String = "gpt-4o-mini",
        timeoutSeconds: TimeInterval = 45
    ) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw OpenAITranslationError.emptyInput
        }

        let source = sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw OpenAITranslationError.invalidTargetLanguage
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = TranslationRequestPayload(
            model: model,
            temperature: 0,
            messages: [
                .init(
                    role: "system",
                    content: "You are a professional translator. Preserve meaning, tone, punctuation, and line breaks. Return only translated text."
                ),
                .init(
                    role: "user",
                    content: """
                    Source language: \(source.isEmpty ? "Auto" : source)
                    Target language: \(target)

                    Translate the text below and return only the translation.

                    \(input)
                    """
                ),
            ]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAITranslationError.timeout
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranslationError.invalidServerResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data) {
                throw OpenAITranslationError.api(
                    statusCode: httpResponse.statusCode,
                    message: payload.error.message
                )
            }
            let fallbackMessage = String(data: data, encoding: .utf8) ?? "Erro de API sem detalhe."
            throw OpenAITranslationError.api(
                statusCode: httpResponse.statusCode,
                message: fallbackMessage
            )
        }

        let completion = try JSONDecoder().decode(TranslationResponsePayload.self, from: data)
        guard let text = completion.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw OpenAITranslationError.emptyOutput
        }

        return text
    }
}

private struct TranslationRequestPayload: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let messages: [Message]
}

private struct TranslationResponsePayload: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct OpenAIErrorPayload: Decodable {
    struct OpenAIError: Decodable {
        let message: String
    }

    let error: OpenAIError
}

private enum OpenAITranslationError: LocalizedError {
    case emptyInput
    case invalidTargetLanguage
    case invalidServerResponse
    case timeout
    case emptyOutput
    case api(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Não foi encontrado texto para traduzir."
        case .invalidTargetLanguage:
            return "Define uma língua de destino válida."
        case .invalidServerResponse:
            return "Resposta inválida da OpenAI na tradução."
        case .timeout:
            return "A tradução demorou demasiado tempo."
        case .emptyOutput:
            return "A OpenAI não devolveu texto traduzido."
        case .api(let statusCode, let message):
            return "Erro OpenAI na tradução (\(statusCode)): \(message)"
        }
    }
}
