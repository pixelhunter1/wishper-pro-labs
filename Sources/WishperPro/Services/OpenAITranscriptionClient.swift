import Foundation

struct OpenAITranscriptionClient {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    /// Transcribes a WAV recording with `gpt-transcribe` (fallback when the live connection fails).
    func transcribe(
        wav: Data,
        apiKey: String,
        languages: [String],
        prompt: String?,
        model: String = "gpt-transcribe",
        timeoutSeconds: TimeInterval = 30
    ) async throws -> String {
        guard wav.count > 44 else { throw OpenAITranscriptionError.emptyAudio }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = Self.multipartBody(
            boundary: boundary,
            fields: Self.formFields(model: model, languages: languages, prompt: prompt),
            wav: wav
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAITranscriptionError.timeout
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.invalidServerResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)
                ?? "Erro de API sem detalhe."
            throw OpenAITranscriptionError.api(statusCode: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(TranscriptionPayload.self, from: data).text
    }

    /// `languages[]` replaces the legacy `language` field for `gpt-transcribe`; never send both.
    static func formFields(model: String, languages: [String], prompt: String?) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [("model", model), ("response_format", "json")]
        fields += languages.map { ("languages[]", $0) }
        if let prompt, !prompt.isEmpty {
            fields.append(("prompt", prompt))
        }
        return fields
    }

    static func multipartBody(boundary: String, fields: [(name: String, value: String)], wav: Data) -> Data {
        var body = Data()
        for field in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

private struct TranscriptionPayload: Decodable {
    let text: String
}

private struct OpenAIErrorPayload: Decodable {
    struct OpenAIError: Decodable {
        let message: String
    }

    let error: OpenAIError
}

private enum OpenAITranscriptionError: LocalizedError {
    case emptyAudio
    case invalidServerResponse
    case timeout
    case api(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "A gravação está vazia."
        case .invalidServerResponse:
            return "Resposta inválida da OpenAI."
        case .timeout:
            return "A transcrição demorou demasiado tempo. Tenta novamente."
        case .api(let statusCode, let message):
            return "Erro OpenAI (\(statusCode)): \(message)"
        }
    }
}
