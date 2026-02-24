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
    case ballad
    case coral
    case cedar
    case echo
    case fable
    case marin
    case onyx
    case nova
    case sage
    case shimmer
    case verse

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var description: String {
        switch self {
        case .alloy: return "Neutra e equilibrada"
        case .ash: return "Suave e clara"
        case .ballad: return "Grave e cinematográfica"
        case .coral: return "Quente e expressiva"
        case .cedar: return "Recomendada pela OpenAI"
        case .echo: return "Grave e ressonante"
        case .fable: return "Narrativa e envolvente"
        case .marin: return "Recomendada pela OpenAI"
        case .onyx: return "Profunda e autoritária"
        case .nova: return "Enérgica e jovem"
        case .sage: return "Calma e sábia"
        case .shimmer: return "Brilhante e otimista"
        case .verse: return "Expressiva e envolvente"
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
    case gpt4oMiniTTS = "gpt-4o-mini-tts"
    case gpt4oMiniTTS20251215 = "gpt-4o-mini-tts-2025-12-15"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tts1: return "TTS-1"
        case .tts1HD: return "TTS-1 HD"
        case .gpt4oMiniTTS: return "GPT-4o Mini TTS"
        case .gpt4oMiniTTS20251215: return "GPT-4o Mini TTS (2025-12-15)"
        }
    }

    var subtitle: String {
        switch self {
        case .tts1: return "Mais rápido"
        case .tts1HD: return "Alta qualidade"
        case .gpt4oMiniTTS: return "Mais natural (13 vozes)"
        case .gpt4oMiniTTS20251215: return "Versão fixa (13 vozes)"
        }
    }

    var supportedVoices: [TTSVoice] {
        switch self {
        case .tts1, .tts1HD:
            return [.alloy, .ash, .coral, .echo, .fable, .onyx, .nova, .sage, .shimmer]
        case .gpt4oMiniTTS, .gpt4oMiniTTS20251215:
            return TTSVoice.allCases
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
