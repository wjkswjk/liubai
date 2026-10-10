import AppKit
import AVFoundation

struct ListeningBookmark: Codable, Equatable {
    let book: String
    let position: Int
    let elapsed: Double
    let voice: String
}

@MainActor
final class ListeningController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum State: Equatable { case idle, loading, playing, paused, failed, finished }
    @Published private(set) var state: State = .idle
    @Published private(set) var message: String?
    @Published private(set) var currentChunk: ListeningChunk?
    @Published private(set) var bookmark: ListeningBookmark?
    @Published var voice: String {
        didSet {
            guard oldValue != voice else { return }
            checkpoint()
            stop()
            if let bookmark {
                self.bookmark = ListeningBookmark(book: bookmark.book, position: bookmark.position, elapsed: 0, voice: voice)
                saveBookmark()
            }
            defaults.set(voice, forKey: "listeningVoice")
        }
    }
    @Published var speed: Double {
        didSet {
            let safe = speed.isFinite ? min(2, max(0.75, speed)) : 1
            if speed != safe { speed = safe }
            player?.rate = Float(safe)
            defaults.set(safe, forKey: "listeningSpeed")
        }
    }
    @Published var followsText: Bool {
        didSet { defaults.set(followsText, forKey: "listeningFollowsText") }
    }
    var onPosition: ((Int) -> Void)?
    private let defaults: UserDefaults
    private let cache: ListeningAudioCache
    private var source: NSString = ""
    private var fingerprint = ""
    private var player: AVAudioPlayer?
    private var loading: Task<Void, Never>?
    private var prefetch: (chunk: ListeningChunk, voice: String, task: Task<URL, Error>)?
    private var generation = UUID()
    private var timer: Timer?

    init(defaults: UserDefaults = .standard, cache: ListeningAudioCache = ListeningAudioCache()) {
        self.defaults = defaults
        self.cache = cache
        let savedVoice = defaults.string(forKey: "listeningVoice") ?? ""
        voice = ListeningVoice.all.contains(where: { $0.id == savedVoice }) ? savedVoice : ListeningVoice.all[0].id
        let savedSpeed = defaults.double(forKey: "listeningSpeed")
        speed = savedSpeed >= 0.75 && savedSpeed <= 2 ? savedSpeed : 1
        followsText = defaults.object(forKey: "listeningFollowsText") as? Bool ?? true
        super.init()
    }

    var canResume: Bool { bookmark?.book == fingerprint && (bookmark?.position ?? source.length) < source.length }
    var isActive: Bool { [.loading, .playing, .paused].contains(state) }
    var status: String {
        switch state {
        case .idle: return "从当前页开始，让文字读给你听"
        case .loading: return "正在准备语音…"
        case .playing: return "正在朗读"
        case .paused: return "已暂停"
        case .failed: return message ?? "暂时无法朗读"
        case .finished: return "这本书已读完"
        }
    }

    func setBook(_ book: Book) {
        stop()
        source = book.text as NSString
        fingerprint = EdgeSpeechProtocol.hash(book.text)
        currentChunk = nil
        bookmark = nil
        if let data = defaults.data(forKey: "listeningBookmark"),
           let saved = try? JSONDecoder().decode(ListeningBookmark.self, from: data),
           saved.book == fingerprint, saved.position >= 0, saved.position < source.length,
           saved.elapsed.isFinite, saved.elapsed >= 0 {
            bookmark = saved
        }
    }

    func start(at position: Int, elapsed: Double = 0) {
        stop()
        message = nil
        load(at: position, elapsed: elapsed)
    }

    func resumeBookmark() {
        guard canResume, let bookmark else { return }
        let elapsed = bookmark.voice == voice ? bookmark.elapsed : 0
        start(at: bookmark.position, elapsed: elapsed)
    }

    func togglePause() {
        switch state {
        case .playing, .loading:
            player?.pause()
            state = .paused
            checkpoint()
        case .paused:
            if let player {
                if player.play() { state = .playing; startTimer() }
                else { fail("无法播放这段语音，请重新开始。") }
            } else { state = .loading }
        default: break
        }
    }

    func stop() {
        checkpoint()
        generation = UUID()
        loading?.cancel()
        loading = nil
        prefetch?.task.cancel()
        prefetch = nil
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        state = .idle
        message = nil
    }

    func checkpoint() {
        guard let chunk = currentChunk, !fingerprint.isEmpty,
              [.loading, .playing, .paused, .failed].contains(state) else { return }
        bookmark = ListeningBookmark(book: fingerprint, position: chunk.range.location,
            elapsed: player?.currentTime ?? (bookmark?.position == chunk.range.location ? bookmark?.elapsed ?? 0 : 0), voice: voice)
        saveBookmark()
    }

    private func saveBookmark() {
        if let bookmark, let data = try? JSONEncoder().encode(bookmark) {
            defaults.set(data, forKey: "listeningBookmark")
        }
    }

    private func load(at position: Int, elapsed: Double = 0) {
        guard let chunk = ListeningChunk.next(in: source, at: position) else {
            state = .finished
            currentChunk = nil
            bookmark = nil
            defaults.removeObject(forKey: "listeningBookmark")
            timer?.invalidate()
            timer = nil
            return
        }
        let token = generation
        let selectedVoice = voice
        let prepared = prefetch?.chunk == chunk && prefetch?.voice == voice ? prefetch?.task : nil
        if prepared == nil { prefetch?.task.cancel() }
        prefetch = nil
        currentChunk = chunk
        player = nil
        state = .loading
        // Keep the original seek time while this cached segment is being prepared.
        bookmark = ListeningBookmark(book: fingerprint, position: chunk.range.location, elapsed: elapsed, voice: voice)
        saveBookmark()
        loading = Task { [weak self, cache] in
            do {
                let url: URL
                if let prepared {
                    url = try await withTaskCancellationHandler(operation: { try await prepared.value }, onCancel: { prepared.cancel() })
                }
                else { url = try await cache.audio(for: chunk, voice: selectedVoice) }
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                let audio: AVAudioPlayer
                do { audio = try AVAudioPlayer(contentsOf: url) }
                catch {
                    await cache.remove(url)
                    throw ListeningError.malformedAudio
                }
                audio.enableRate = true
                audio.rate = Float(self.speed)
                audio.delegate = self
                guard audio.prepareToPlay() else { throw ListeningError.malformedAudio }
                audio.currentTime = min(max(0, elapsed), max(0, audio.duration - 0.05))
                self.player = audio
                self.loading = nil
                if self.state != .paused {
                    guard audio.play() else { throw ListeningError.malformedAudio }
                    self.state = .playing
                    self.startTimer()
                }
                if self.followsText { self.onPosition?(chunk.range.location) }
                if let next = ListeningChunk.next(in: self.source, at: chunk.nextPosition) {
                    let task = Task { try await cache.audio(for: next, voice: selectedVoice) }
                    self.prefetch = (next, selectedVoice, task)
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.loading = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpoint() }
        }
    }

    private func fail(_ text: String) {
        checkpoint()
        state = .failed
        message = text
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        prefetch?.task.cancel()
        prefetch = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, self.state == .playing, let chunk = self.currentChunk else { return }
            if flag { self.load(at: chunk.nextPosition) }
            else { self.fail("语音播放中断，请重试。") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.fail("无法播放这段语音，请重试。")
        }
    }
}
