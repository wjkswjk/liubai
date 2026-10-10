import Foundation
import CryptoKit

struct ListeningVoice: Identifiable, Equatable {
    let id: String
    let name: String
    static let all = [
        ListeningVoice(id: "zh-CN-XiaoxiaoNeural", name: "晓晓 · 女声"),
        ListeningVoice(id: "zh-CN-YunxiNeural", name: "云希 · 男声"),
        ListeningVoice(id: "zh-CN-XiaoyiNeural", name: "晓伊 · 女声"),
        ListeningVoice(id: "zh-CN-YunjianNeural", name: "云健 · 男声")
    ]
}

struct ListeningChunk: Equatable {
    let text: String
    let range: NSRange
    let nextPosition: Int

    // Only inspect a small window, even when the book is tens of megabytes.
    static func next(in source: NSString, at position: Int) -> ListeningChunk? {
        var start = min(max(0, position), source.length)
        if start < source.length { start = source.rangeOfComposedCharacterSequence(at: start).location }
        while start < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: start)
            if !source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            start = NSMaxRange(range)
        }
        guard start < source.length else { return nil }
        var end = start
        var boundary: Int?
        var bytes = 0
        while end < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: end)
            let character = source.substring(with: range)
            let cost = EdgeSpeechProtocol.escape(character).utf8.count
            if end > start && (end - start >= 300 || bytes + cost > 3500) { break }
            end = NSMaxRange(range)
            bytes += cost
            if end - start >= 100 && character.rangeOfCharacter(from: CharacterSet(charactersIn: "\n。！？!?；;")) != nil {
                boundary = end
            }
        }
        if end < source.length, let boundary { end = boundary }
        let range = NSRange(location: start, length: end - start)
        return ListeningChunk(text: source.substring(with: range), range: range, nextPosition: end)
    }
}

enum ListeningError: LocalizedError {
    case service, timeout, malformedAudio, noAudio
    var errorDescription: String? {
        switch self {
        case .service: return "暂时连接不上微软语音服务，请检查网络后重试。"
        case .timeout: return "生成语音超时，请稍后重试。"
        case .malformedAudio: return "语音服务返回了无法识别的数据，请重试。"
        case .noAudio: return "没有收到语音，请换一个音色或稍后重试。"
        }
    }
}

// Native implementation of the Edge Read Aloud wire protocol used by edge-tts.
// Protocol reference: https://github.com/rany2/edge-tts (see README for provenance).
enum EdgeSpeechProtocol {
    static let token = "6A5AA1D4EAFF4E9FB37E23D68491D6F4" // Public Edge client identifier, not a user credential.
    static let version = "143.0.3650.75"
    static let outputFormat = "audio-24khz-48kbitrate-mono-mp3"

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func escape(_ text: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let value = scalar.value
            return (value < 32 && value != 9 && value != 10 && value != 13) || value == 0xFFFE || value == 0xFFFF
                ? UnicodeScalar(32)! : scalar
        }))
        return cleaned.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func gec(at date: Date) -> String {
        let seconds = date.timeIntervalSince1970 + 11_644_473_600
        let ticks = UInt64(floor(seconds / 300) * 300) * 10_000_000
        return hash(String(ticks) + token).uppercased()
    }

    static func request(at date: Date = Date()) -> URLRequest {
        var url = URLComponents(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        url.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: token),
            URLQueryItem(name: "ConnectionId", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
            URLQueryItem(name: "Sec-MS-GEC", value: gec(at: date)),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: "1-" + version)
        ]
        var request = URLRequest(url: url.url!, timeoutInterval: 45)
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + ";", forHTTPHeaderField: "Cookie")
        return request
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: date)
    }

    static var configuration: String {
        "X-Timestamp:\(timestamp())\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" +
        "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"\(outputFormat)\"}}}}\r\n"
    }

    static func ssml(text: String, voice: String) -> String {
        let parts = voice.split(separator: "-", maxSplits: 2)
        let name = parts.count == 3 ? "Microsoft Server Speech Text to Speech Voice (\(parts[0])-\(parts[1]), \(parts[2]))" : voice
        return "X-RequestId:\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp())Z\r\nPath:ssml\r\n\r\n" +
        "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='\(escape(name))'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>\(escape(text))</prosody></voice></speak>"
    }

    static func headers(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in string.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func audioPayload(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw ListeningError.malformedAudio }
        let length = Int(bytes[0]) * 256 + Int(bytes[1])
        guard length > 0, length + 2 <= bytes.count,
              let header = String(bytes: bytes[2..<(length + 2)], encoding: .utf8) else { throw ListeningError.malformedAudio }
        let fields = headers(header)
        guard fields["path"] == "audio" else { throw ListeningError.malformedAudio }
        let payload = Data(bytes.dropFirst(length + 2))
        if fields["content-type"] == nil && payload.isEmpty { return payload }
        guard fields["content-type"] == "audio/mpeg", !payload.isEmpty else { throw ListeningError.malformedAudio }
        return payload
    }
}

protocol SpeechSynthesizing {
    func synthesize(text: String, voice: String) async throws -> Data
}

struct EdgeSpeechClient: SpeechSynthesizing {
    func synthesize(text: String, voice: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 50
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var date = Date()
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let socket = session.webSocketTask(with: EdgeSpeechProtocol.request(at: date))
            socket.maximumMessageSize = 2 * 1024 * 1024
            socket.resume()
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            do {
                return try await withTaskCancellationHandler(operation: {
                    try await withThrowingTaskGroup(of: Data.self) { group in
                        group.addTask {
                            try await socket.send(.string(EdgeSpeechProtocol.configuration))
                            try await socket.send(.string(EdgeSpeechProtocol.ssml(text: text, voice: voice)))
                            var audio = Data()
                            while true {
                                try Task.checkCancellation()
                                switch try await socket.receive() {
                                case .data(let data):
                                    audio.append(try EdgeSpeechProtocol.audioPayload(data))
                                    guard audio.count <= 8 * 1024 * 1024 else { throw ListeningError.malformedAudio }
                                case .string(let message):
                                    let head = message.components(separatedBy: "\r\n\r\n").first ?? ""
                                    let path = EdgeSpeechProtocol.headers(head)["path"]
                                    if path == "turn.end" {
                                        guard !audio.isEmpty else { throw ListeningError.noAudio }
                                        return audio
                                    }
                                    if path == "response", message.contains("\"error\"") { throw ListeningError.service }
                                @unknown default: throw ListeningError.malformedAudio
                                }
                            }
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 45_000_000_000)
                            socket.cancel(with: .goingAway, reason: nil)
                            throw ListeningError.timeout
                        }
                        defer { group.cancelAll() }
                        return try await group.next()!
                    }
                }, onCancel: { socket.cancel(with: .goingAway, reason: nil) })
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // Edge checks the time-derived client token. Correct skew once on rejection.
                if attempt == 0, let response = socket.response as? HTTPURLResponse, response.statusCode == 403,
                   let value = response.value(forHTTPHeaderField: "Date") {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    if let serverDate = formatter.date(from: value) { date = serverDate; continue }
                }
                if let error = error as? ListeningError { throw error }
                throw ListeningError.service
            }
        }
        throw ListeningError.service
    }
}

actor ListeningAudioCache {
    let directory: URL
    let client: any SpeechSynthesizing
    private let limit = 256 * 1024 * 1024

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("cn.liubai.reader/Listening", isDirectory: true), client: any SpeechSynthesizing = EdgeSpeechClient()) {
        self.directory = directory
        self.client = client
    }

    static func key(text: String, voice: String) -> String {
        EdgeSpeechProtocol.hash("edge-v1\n" + EdgeSpeechProtocol.outputFormat + "\n" + voice + "\n" + text)
    }

    func audio(for chunk: ListeningChunk, voice: String) async throws -> URL {
        let url = directory.appendingPathComponent(Self.key(text: chunk.text, voice: voice) + ".mp3")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }
        let data = try await client.synthesize(text: chunk.text, voice: voice)
        try Task.checkCancellation()
        guard !data.isEmpty else { throw ListeningError.noAudio }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        trim(keeping: url)
        return url
    }

    func remove(_ url: URL) {
        guard url.deletingLastPathComponent() == directory else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func trim(keeping current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { $0.pathExtension == "mp3" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in entries where size > limit && url != current {
            if (try? FileManager.default.removeItem(at: url)) != nil { size -= bytes }
        }
    }
}
