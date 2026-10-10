import Foundation
#if !STANDALONE_TESTS
import XCTest
@testable import Liubai
#endif

actor TestSpeechClient: SpeechSynthesizing {
    private(set) var calls = 0
    private(set) var cancellations = 0
    let delay: UInt64
    init(delay: UInt64 = 0) { self.delay = delay }

    func synthesize(text: String, voice: String) async throws -> Data {
        calls += 1
        do { if delay > 0 { try await Task.sleep(nanoseconds: delay) } }
        catch { cancellations += 1; throw error }
        // A short real service response, exercising the same decoder/format as production.
        #if STANDALONE_TESTS
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/speech.mp3")
        #else
        let url = Bundle.module.url(forResource: "speech", withExtension: "mp3", subdirectory: "Fixtures")!
        #endif
        return try Data(contentsOf: url)
    }
}

@MainActor
final class ListeningTests: XCTestCase {
    func testLongBookChunksCoverUnicodeAndCrossChapters() {
        let text = "  第一章 😀\n" + String(repeating: "窗外有风，家人说：“回来吧。”👨‍👩‍👧‍👦\n", count: 80) + "第二章\n最后一句。"
        let source = text as NSString
        var position = 0
        var collected = ""
        var count = 0
        while let chunk = ListeningChunk.next(in: source, at: position) {
            XCTAssertTrue(chunk.nextPosition > position)
            XCTAssertEqual(source.substring(with: chunk.range), chunk.text)
            XCTAssertTrue(EdgeSpeechProtocol.escape(chunk.text).utf8.count <= 4096)
            collected += chunk.text
            position = chunk.nextPosition
            count += 1
        }
        XCTAssertTrue(count > 5)
        XCTAssertEqual(collected.components(separatedBy: .whitespacesAndNewlines).joined(),
                       text.components(separatedBy: .whitespacesAndNewlines).joined())
        XCTAssertEqual(position, source.length)
        XCTAssertEqual(ListeningChunk.next(in: "😀正文", at: 1)?.range.location, 0)
        XCTAssertEqual(ListeningChunk.next(in: "  \n", at: 0), nil)
    }

    func testEscapingAndByteLimitForXMLHeavyText() {
        XCTAssertEqual(EdgeSpeechProtocol.escape("<&>'\"\u{0}😀"), "&lt;&amp;&gt;&apos;&quot; 😀")
        let text = String(repeating: "<>&\"'😀", count: 2000) as NSString
        var position = 0
        var collected = ""
        while let chunk = ListeningChunk.next(in: text, at: position) {
            XCTAssertTrue(EdgeSpeechProtocol.escape(chunk.text).utf8.count <= 3500)
            collected += chunk.text
            position = chunk.nextPosition
        }
        XCTAssertEqual(collected, text as String)
    }

    func testAudioFramesRejectTruncationAndAcceptEndMarker() throws {
        func frame(_ header: String, payload: Data = Data()) -> Data {
            let bytes = Data(header.utf8)
            var data = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 255)])
            data.append(bytes); data.append(payload)
            return data
        }
        XCTAssertEqual(try EdgeSpeechProtocol.audioPayload(frame("Path:audio\r\nContent-Type:audio/mpeg\r\n", payload: Data([1, 2, 3]))), Data([1, 2, 3]))
        XCTAssertEqual(try EdgeSpeechProtocol.audioPayload(frame("Path:audio\r\n")), Data())
        for broken in [Data(), Data([0]), Data([0, 30, 1]), frame("Path:other\r\n"), frame("Path:audio\r\n", payload: Data([1]))] {
            do { _ = try EdgeSpeechProtocol.audioPayload(broken); XCTAssertTrue(false) }
            catch { XCTAssertTrue(error is ListeningError) }
        }
    }

    func testTokenAndSSMLMatchServiceContract() {
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(EdgeSpeechProtocol.gec(at: epoch), "7ECB79D14E3AA576D2D79E6D487A1388156D91E614B1BE11C64226A29BC8DD8C")
        XCTAssertEqual(EdgeSpeechProtocol.gec(at: epoch.addingTimeInterval(299)), EdgeSpeechProtocol.gec(at: epoch))
        XCTAssertFalse(EdgeSpeechProtocol.gec(at: epoch.addingTimeInterval(300)) == EdgeSpeechProtocol.gec(at: epoch))
        let message = EdgeSpeechProtocol.ssml(text: "<正文>&", voice: "zh-CN-XiaoxiaoNeural")
        XCTAssertTrue(message.contains("Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)"))
        XCTAssertTrue(message.contains("&lt;正文&gt;&amp;"))
        XCTAssertTrue(message.contains("Path:ssml\r\n\r\n"))
        XCTAssertTrue(PagingKey(keyCode: 37, flags: .command, name: "L").isReserved)
    }

    func testAudioCacheReusesTextAndSeparatesVoices() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TestSpeechClient()
        let cache = ListeningAudioCache(directory: directory, client: client)
        let chunk = ListeningChunk.next(in: "同一段文字。", at: 0)!
        let first = try await cache.audio(for: chunk, voice: "女声")
        let again = try await cache.audio(for: chunk, voice: "女声")
        let male = try await cache.audio(for: chunk, voice: "男声")
        XCTAssertEqual(first, again)
        XCTAssertFalse(first == male)
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
        XCTAssertTrue((try Data(contentsOf: first)).count > 0)
    }

    func testPauseWhileLoadingPreservesResumeTimeAndBookmark() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ListeningTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let cache = ListeningAudioCache(directory: directory, client: TestSpeechClient(delay: 80_000_000))
        let controller = ListeningController(defaults: defaults, cache: cache)
        let book = Book(title: "测试", text: "第一段。\n第二段。")
        controller.setBook(book)
        controller.start(at: 5, elapsed: 0.4)
        controller.togglePause()
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.bookmark?.elapsed, 0.4)
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(controller.state, .paused)
        controller.stop()
        let restored = ListeningController(defaults: defaults, cache: cache)
        restored.setBook(book)
        XCTAssertTrue(restored.canResume)
        XCTAssertEqual(restored.bookmark?.position, 5)
        XCTAssertTrue(abs((restored.bookmark?.elapsed ?? 0) - 0.4) < 0.05)
        restored.voice = "zh-CN-YunxiNeural"
        XCTAssertEqual(restored.bookmark?.elapsed, 0)
        restored.setBook(Book(title: "另一书", text: "不同的正文。"))
        XCTAssertFalse(restored.canResume)
    }

    func testStopAndBookChangeCancelLoadingWithoutStaleCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ListeningTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let client = TestSpeechClient(delay: 300_000_000)
        let controller = ListeningController(defaults: defaults, cache: ListeningAudioCache(directory: directory, client: client))
        var positions: [Int] = []
        controller.onPosition = { positions.append($0) }
        controller.setBook(Book(title: "旧书", text: "旧的正文。"))
        controller.start(at: 0)
        try await Task.sleep(nanoseconds: 40_000_000)
        controller.setBook(Book(title: "新书", text: "新的正文。"))
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.currentChunk, nil)
        XCTAssertTrue(positions.isEmpty)
        let cancellations = await client.cancellations
        XCTAssertEqual(cancellations, 1)
    }
}
