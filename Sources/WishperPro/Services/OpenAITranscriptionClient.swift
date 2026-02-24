import Foundation

struct OpenAITranscriptionClient {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    func transcribeAudio(
        fileURL: URL,
        apiKey: String,
        model: String = "gpt-4o-transcribe",
        timeoutSeconds: TimeInterval = 30
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
            model: model
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
                throw OpenAITranscriptionError.api(payload.error.message)
            }

            let fallbackMessage = String(data: data, encoding: .utf8) ?? "Erro de API sem detalhe."
            throw OpenAITranscriptionError.api(fallbackMessage)
        }

        let parsed = try JSONDecoder().decode(TranscriptionPayload.self, from: data)
        return parsed.text
    }

    private func makeMultipartBody(
        fileURL: URL,
        boundary: String,
        model: String
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

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        )
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
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
    case api(String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "A gravação está vazia."
        case .invalidServerResponse:
            return "Resposta inválida da OpenAI."
        case .timeout:
            return "A transcrição demorou demasiado tempo. Tenta novamente."
        case .api(let message):
            return "Erro OpenAI: \(message)"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}
