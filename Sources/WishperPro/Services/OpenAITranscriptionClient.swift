import Foundation

struct OpenAITranscriptionClient {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    func transcribeAudio(
        fileURL: URL,
        apiKey: String,
        model: String = "gpt-4o-transcribe",
        languageHint: String? = nil,
        timeoutSeconds: TimeInterval = 75,
        maxRetries: Int = 1
    ) async throws -> String {
        let retryCount = max(0, maxRetries)
        var lastError: Error?

        for attempt in 0...retryCount {
            do {
                return try await transcribeOnce(
                    fileURL: fileURL,
                    apiKey: apiKey,
                    model: model,
                    languageHint: languageHint,
                    timeoutSeconds: timeoutSeconds
                )
            } catch {
                lastError = error
                let canRetry = shouldRetry(error) && attempt < retryCount
                guard canRetry else {
                    throw error
                }

                try? await Task.sleep(for: .milliseconds(650 * (attempt + 1)))
            }
        }

        throw lastError ?? OpenAITranscriptionError.invalidServerResponse
    }

    private func transcribeOnce(
        fileURL: URL,
        apiKey: String,
        model: String,
        languageHint: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try makeMultipartBody(
            fileURL: fileURL,
            boundary: boundary,
            model: model,
            languageHint: languageHint
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAITranscriptionError.timeout
        } catch {
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.invalidServerResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data) {
                throw OpenAITranscriptionError.api(
                    statusCode: httpResponse.statusCode,
                    message: payload.error.message
                )
            }

            let fallbackMessage = String(data: data, encoding: .utf8) ?? "Erro de API sem detalhe."
            throw OpenAITranscriptionError.api(
                statusCode: httpResponse.statusCode,
                message: fallbackMessage
            )
        }

        let parsed = try JSONDecoder().decode(TranscriptionPayload.self, from: data)
        return parsed.text
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let transcriptionError = error as? OpenAITranscriptionError {
            return transcriptionError.isRetryable
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        return false
    }

    private func makeMultipartBody(
        fileURL: URL,
        boundary: String,
        model: String,
        languageHint: String?
    ) throws -> Data {
        let audioData = try Data(contentsOf: fileURL)
        guard !audioData.isEmpty else {
            throw OpenAITranscriptionError.emptyAudio
        }

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendUTF8("\(model)\r\n")

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendUTF8("json\r\n")

        if let languageHint = languageHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !languageHint.isEmpty {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.appendUTF8("\(languageHint)\r\n")
        }

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        )
        body.appendUTF8("Content-Type: audio/mp4\r\n\r\n")
        body.append(audioData)
        body.appendUTF8("\r\n")

        body.appendUTF8("--\(boundary)--\r\n")
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

    var isRetryable: Bool {
        switch self {
        case .timeout:
            return true
        case .api(let statusCode, _):
            return statusCode == 429 || statusCode >= 500
        default:
            return false
        }
    }

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

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}
