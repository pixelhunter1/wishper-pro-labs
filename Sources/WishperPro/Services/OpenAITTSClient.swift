import Foundation

struct OpenAITTSClient {
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!

    func synthesize(
        text: String,
        apiKey: String,
        voice: TTSVoice = .alloy,
        model: TTSModel = .tts1,
        timeoutSeconds: TimeInterval = 60
    ) async throws -> Data {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw OpenAITTSError.emptyInput
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = TTSRequestPayload(
            model: model.rawValue,
            input: input,
            voice: voice.rawValue,
            response_format: "mp3"
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw OpenAITTSError.timeout
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITTSError.invalidServerResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let payload = try? JSONDecoder().decode(OpenAITTSErrorPayload.self, from: data) {
                throw OpenAITTSError.api(
                    statusCode: httpResponse.statusCode,
                    message: payload.error.message
                )
            }
            let fallbackMessage = String(data: data, encoding: .utf8) ?? "Erro de API sem detalhe."
            throw OpenAITTSError.api(
                statusCode: httpResponse.statusCode,
                message: fallbackMessage
            )
        }

        guard !data.isEmpty else {
            throw OpenAITTSError.emptyAudio
        }

        return data
    }
}

enum TTSVoice: String, CaseIterable, Identifiable, Codable {
    case alloy
    case ash
    case coral
    case echo
    case fable
    case onyx
    case nova
    case sage
    case shimmer

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var description: String {
        switch self {
        case .alloy: return "Neutra e equilibrada"
        case .ash: return "Suave e clara"
        case .coral: return "Quente e expressiva"
        case .echo: return "Grave e ressonante"
        case .fable: return "Narrativa e envolvente"
        case .onyx: return "Profunda e autoritária"
        case .nova: return "Enérgica e jovem"
        case .sage: return "Calma e sábia"
        case .shimmer: return "Brilhante e otimista"
        }
    }

    func previewText(for portugueseVariant: PortugueseVariant) -> String {
        switch portugueseVariant {
        case .portugal:
            return "Olá, sou a voz \(displayName). Esta é a minha forma de falar quando leio um texto para ti."
        case .brazil:
            return "Olá, eu sou a voz \(displayName). Assim é como eu soo quando leio um texto para você."
        }
    }
}

enum TTSModel: String, CaseIterable, Identifiable, Codable {
    case tts1 = "tts-1"
    case tts1HD = "tts-1-hd"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tts1: return "TTS-1"
        case .tts1HD: return "TTS-1 HD"
        }
    }

    var subtitle: String {
        switch self {
        case .tts1: return "Mais rápido"
        case .tts1HD: return "Alta qualidade"
        }
    }
}

private struct TTSRequestPayload: Encodable {
    let model: String
    let input: String
    let voice: String
    let response_format: String
}

private struct OpenAITTSErrorPayload: Decodable {
    struct OpenAIError: Decodable {
        let message: String
    }

    let error: OpenAIError
}

private enum OpenAITTSError: LocalizedError {
    case emptyInput
    case emptyAudio
    case invalidServerResponse
    case timeout
    case api(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Não foi encontrado texto para reproduzir."
        case .emptyAudio:
            return "A OpenAI não devolveu áudio."
        case .invalidServerResponse:
            return "Resposta inválida da OpenAI no TTS."
        case .timeout:
            return "A geração de voz demorou demasiado tempo."
        case .api(let statusCode, let message):
            return "Erro OpenAI TTS (\(statusCode)): \(message)"
        }
    }
}
