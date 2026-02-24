import AVFoundation
import Foundation

struct OpenAITranscriptionResult {
    let text: String
    let metrics: OpenAITranscriptionMetrics
}

struct OpenAITranscriptionMetrics {
    let model: String
    let languageHint: String?
    let audioBytes: Int
    let audioDurationSeconds: TimeInterval?
    let totalElapsedSeconds: TimeInterval
    let attempts: [OpenAITranscriptionAttemptMetrics]
}

struct OpenAITranscriptionAttemptMetrics {
    let number: Int
    let elapsedSeconds: TimeInterval
    let statusCode: Int?
    let openAIProcessingMilliseconds: Int?
    let failureReason: String?
}

struct OpenAITranscriptionClient {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    func transcribeAudio(
        fileURL: URL,
        apiKey: String,
        model: String = "gpt-4o-transcribe",
        languageHint: String? = nil,
        timeoutSeconds: TimeInterval = 75,
        maxRetries: Int = 1
    ) async throws -> OpenAITranscriptionResult {
        let retryCount = max(0, maxRetries)
        let audioData = try Data(contentsOf: fileURL)
        guard !audioData.isEmpty else {
            throw OpenAITranscriptionError.emptyAudio
        }

        let audioDurationSeconds = Self.audioDurationSeconds(for: fileURL)
        let requestStartTime = Date()
        var attempts: [OpenAITranscriptionAttemptMetrics] = []
        var lastError: Error?

        for attempt in 0...retryCount {
            let attemptStartTime = Date()
            do {
                let response = try await transcribeOnce(
                    audioData: audioData,
                    fileName: fileURL.lastPathComponent,
                    apiKey: apiKey,
                    model: model,
                    languageHint: languageHint,
                    timeoutSeconds: timeoutSeconds
                )
                attempts.append(
                    OpenAITranscriptionAttemptMetrics(
                        number: attempt + 1,
                        elapsedSeconds: Date().timeIntervalSince(attemptStartTime),
                        statusCode: response.statusCode,
                        openAIProcessingMilliseconds: response.openAIProcessingMilliseconds,
                        failureReason: nil
                    )
                )

                return OpenAITranscriptionResult(
                    text: response.text,
                    metrics: OpenAITranscriptionMetrics(
                        model: model,
                        languageHint: languageHint,
                        audioBytes: audioData.count,
                        audioDurationSeconds: audioDurationSeconds,
                        totalElapsedSeconds: Date().timeIntervalSince(requestStartTime),
                        attempts: attempts
                    )
                )
            } catch {
                lastError = error
                attempts.append(
                    OpenAITranscriptionAttemptMetrics(
                        number: attempt + 1,
                        elapsedSeconds: Date().timeIntervalSince(attemptStartTime),
                        statusCode: statusCode(from: error),
                        openAIProcessingMilliseconds: openAIProcessingMilliseconds(from: error),
                        failureReason: failureReason(from: error)
                    )
                )

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
        audioData: Data,
        fileName: String,
        apiKey: String,
        model: String,
        languageHint: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> TranscribeOnceResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let body = makeMultipartBody(
            audioData: audioData,
            fileName: fileName,
            boundary: boundary,
            model: model,
            languageHint: languageHint
        )

        let session = Self.makeSession(timeoutSeconds: timeoutSeconds)
        defer {
            session.finishTasksAndInvalidate()
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAITranscriptionError.timeout
        } catch {
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionError.invalidServerResponse
        }

        let openAIProcessingMilliseconds = Self.parseOpenAIProcessingMilliseconds(from: httpResponse)

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data) {
                throw OpenAITranscriptionError.api(
                    statusCode: httpResponse.statusCode,
                    message: payload.error.message,
                    openAIProcessingMilliseconds: openAIProcessingMilliseconds
                )
            }

            let fallbackMessage = String(data: data, encoding: .utf8) ?? "Erro de API sem detalhe."
            throw OpenAITranscriptionError.api(
                statusCode: httpResponse.statusCode,
                message: fallbackMessage,
                openAIProcessingMilliseconds: openAIProcessingMilliseconds
            )
        }

        let parsed = try JSONDecoder().decode(TranscriptionPayload.self, from: data)
        return TranscribeOnceResponse(
            text: parsed.text,
            statusCode: httpResponse.statusCode,
            openAIProcessingMilliseconds: openAIProcessingMilliseconds
        )
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

    private func statusCode(from error: Error) -> Int? {
        guard let transcriptionError = error as? OpenAITranscriptionError else {
            return nil
        }

        if case let .api(statusCode, _, _) = transcriptionError {
            return statusCode
        }

        return nil
    }

    private func openAIProcessingMilliseconds(from error: Error) -> Int? {
        guard let transcriptionError = error as? OpenAITranscriptionError else {
            return nil
        }

        if case let .api(_, _, openAIProcessingMilliseconds) = transcriptionError {
            return openAIProcessingMilliseconds
        }

        return nil
    }

    private func failureReason(from error: Error) -> String {
        if let transcriptionError = error as? OpenAITranscriptionError {
            switch transcriptionError {
            case .emptyAudio:
                return "empty_audio"
            case .invalidServerResponse:
                return "invalid_response"
            case .timeout:
                return "timeout"
            case .api(let statusCode, _, _):
                return "http_\(statusCode)"
            }
        }

        if let urlError = error as? URLError {
            return "url_\(urlError.code.rawValue)"
        }

        return "unexpected_error"
    }

    private func makeMultipartBody(
        audioData: Data,
        fileName: String,
        boundary: String,
        model: String,
        languageHint: String?
    ) -> Data {
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
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
        )
        body.appendUTF8("Content-Type: audio/mp4\r\n\r\n")
        body.append(audioData)
        body.appendUTF8("\r\n")

        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }

    private static func parseOpenAIProcessingMilliseconds(from response: HTTPURLResponse) -> Int? {
        guard let rawHeaderValue = response.value(forHTTPHeaderField: "openai-processing-ms")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawHeaderValue.isEmpty else {
            return nil
        }

        if let milliseconds = Int(rawHeaderValue) {
            return milliseconds
        }

        if let milliseconds = Double(rawHeaderValue) {
            return Int(milliseconds.rounded())
        }

        return nil
    }

    private static func makeSession(timeoutSeconds: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds + 5
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldUsePipelining = false
        return URLSession(configuration: configuration)
    }

    private static func audioDurationSeconds(for fileURL: URL) -> TimeInterval? {
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else {
            return nil
        }

        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else {
            return nil
        }

        let durationSeconds = Double(audioFile.length) / sampleRate
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return nil
        }
        return durationSeconds
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

private struct TranscribeOnceResponse {
    let text: String
    let statusCode: Int
    let openAIProcessingMilliseconds: Int?
}

private enum OpenAITranscriptionError: LocalizedError {
    case emptyAudio
    case invalidServerResponse
    case timeout
    case api(statusCode: Int, message: String, openAIProcessingMilliseconds: Int?)

    var isRetryable: Bool {
        switch self {
        case .timeout:
            return true
        case .api(let statusCode, _, _):
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
        case .api(let statusCode, let message, _):
            return "Erro OpenAI (\(statusCode)): \(message)"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}
