import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PanelTab: String, CaseIterable, Identifiable {
    case chapters = "目录", search = "搜索", appearance = "外观", shortcuts = "快捷键"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .chapters: return "list.bullet"
        case .search: return "magnifyingglass"
        case .appearance: return "textformat.size"
        case .shortcuts: return "keyboard"
        }
    }
}

struct ReaderPreferences: Codable, Equatable {
    var fontName = "Songti SC"
    var fontSize: Double = 22
    var lineSpacing: Double = 12
    var margin: Double = 48
    var background = "F7F8FA"
    var foreground = "383D44"
    var backgroundOpacity: Double = 1

    init() {}

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, lineSpacing, margin, background, foreground, backgroundOpacity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        lineSpacing = try values.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? lineSpacing
        margin = try values.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        background = try values.decodeIfPresent(String.self, forKey: .background) ?? background
        foreground = try values.decodeIfPresent(String.self, forKey: .foreground) ?? foreground
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
        sanitize()
    }

    var readingBackground: NSColor {
        NSColor(hex: background).withAlphaComponent(backgroundOpacity)
    }

    func hasSameTextStyle(as other: Self) -> Bool {
        fontName == other.fontName && fontSize == other.fontSize && lineSpacing == other.lineSpacing &&
            margin == other.margin && foreground == other.foreground
    }

    static let themes: [(name: String, background: String, foreground: String)] = [
        ("素白", "FAFAF8", "343735"),
        ("雾灰", "F7F8FA", "383D44"),
        ("暖纸", "F3EBDC", "514637"),
        ("青绿", "E9EFEA", "354B3D"),
        ("夜读", "1D2026", "C6CAD1")
    ]

    var nsFont: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    }

    mutating func sanitize() {
        fontSize = min(48, max(12, fontSize.isFinite ? fontSize : 22))
        lineSpacing = min(30, max(2, lineSpacing.isFinite ? lineSpacing : 12))
        margin = min(160, max(16, margin.isFinite ? margin : 48))
        backgroundOpacity = min(1, max(0, backgroundOpacity.isFinite ? backgroundOpacity : 1))
        if !NSColor.isValidHex(background) { background = "F7F8FA" }
        if !NSColor.isValidHex(foreground) { foreground = "383D44" }
    }
}

struct JumpRequest {
    let id = UUID()
    let range: NSRange
    let highlight: Bool
}

@MainActor
final class ReaderModel: ObservableObject {
    @Published var book: Book?
    @Published var bookID = UUID()
    @Published var panel: PanelTab? {
        didSet { if panel != .shortcuts { recordingShortcut = nil; shortcutMessage = nil } }
    }
    @Published var preferences: ReaderPreferences {
        didSet { savePreferences() }
    }
    @Published var query = "" { didSet { search() } }
    @Published var searchResults: [SearchResult] = []
    @Published var searchTotal = 0
    @Published var isSearching = false
    @Published var isLoading = false
    @Published var dragOver = false
    @Published var errorMessage: String?
    @Published var currentPosition = 0
    @Published var progress: Double = 0
    @Published var jump: JumpRequest?
    @Published var pageRequest: PageRequest?
    @Published var recordingShortcut: PageDirection?
    @Published var shortcutMessage: String?
    @Published var pagingShortcuts: PagingShortcuts {
        didSet {
            if let data = try? JSONEncoder().encode(pagingShortcuts) {
                UserDefaults.standard.set(data, forKey: "pagingShortcuts")
            }
        }
    }
    private var searchTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadID = UUID()
    private var filePicker: NSOpenPanel?
    weak var window: NSWindow?
    var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("cn.liubai.reader", isDirectory: true).appendingPathComponent("CurrentBook.json")
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "pagingShortcuts"),
           let saved = try? JSONDecoder().decode(PagingShortcuts.self, from: data), saved.isValid {
            pagingShortcuts = saved
        } else { pagingShortcuts = PagingShortcuts() }
        if let data = UserDefaults.standard.data(forKey: "appearance"),
           var saved = try? JSONDecoder().decode(ReaderPreferences.self, from: data) {
            saved.sanitize()
            preferences = saved
        } else { preferences = ReaderPreferences() }
    }

    func restore() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        isLoading = true
        let url = cacheURL
        let token = UUID()
        loadID = token
        importTask = Task {
            let saved = await Task.detached(priority: .userInitiated) {
                guard let data = try? Data(contentsOf: url) else { return Optional<Book>.none }
                return try? JSONDecoder().decode(Book.self, from: data)
            }.value
            guard loadID == token else { return }
            if let saved {
                present(saved, persist: false)
                let position = UserDefaults.standard.integer(forKey: "readingPosition")
                currentPosition = max(0, min(position, (saved.text as NSString).length))
                progress = min(1, max(0, UserDefaults.standard.double(forKey: "readingProgress")))
                jump = JumpRequest(range: NSRange(location: currentPosition, length: 0), highlight: false)
            }
            isLoading = false
        }
    }

    func openFile() {
        if let filePicker { filePicker.makeKeyAndOrderFront(nil); return }
        let picker = NSOpenPanel()
        filePicker = picker
        picker.title = "打开一本 TXT"
        picker.prompt = "开始阅读"
        picker.allowedContentTypes = [.plainText, UTType(filenameExtension: "txt")!]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak picker] response in
            defer { self?.filePicker = nil }
            guard response == .OK, let url = picker?.url else { return }
            self?.load(url)
        }
        if let window { picker.beginSheetModal(for: window, completionHandler: completion) }
        else { picker.begin(completionHandler: completion) }
    }

    func load(_ url: URL) {
        importTask?.cancel()
        let token = UUID()
        loadID = token
        isLoading = true
        panel = nil
        importTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Book, Error> in
                do {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 30 * 1024 * 1024 else { throw ReaderError.tooLarge }
                    let text = try Book.decode(Data(contentsOf: url))
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReaderError.empty }
                    return .success(Book(title: url.deletingPathExtension().lastPathComponent, text: text))
                } catch { return .failure(error) }
            }.value
            guard loadID == token else { return }
            isLoading = false
            switch result {
            case .success(let book): present(book)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    func present(_ newBook: Book, persist: Bool = true) {
        book = newBook
        bookID = UUID()
        panel = nil
        query = ""
        currentPosition = 0
        progress = 0
        pageRequest = nil
        jump = JumpRequest(range: NSRange(location: 0, length: 0), highlight: false)
        window?.title = newBook.title + " — 留白"
        if persist {
            UserDefaults.standard.set(0, forKey: "readingPosition")
            UserDefaults.standard.set(0.0, forKey: "readingProgress")
            saveTask?.cancel()
            let url = cacheURL
            saveTask = Task {
                let failure = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let data = try JSONEncoder().encode(newBook)
                        try data.write(to: url, options: .atomic)
                        return nil
                    } catch { return "无法保存阅读记录：" + error.localizedDescription }
                }.value
                if let failure { errorMessage = failure }
            }
        }
    }

    func togglePanel(_ tab: PanelTab? = nil) {
        if let tab { panel = tab }
        else { panel = panel == nil ? .chapters : nil }
    }

    func page(_ direction: PageDirection) {
        guard book != nil, panel == nil, !isLoading else { return }
        pageRequest = PageRequest(direction: direction)
    }

    func recordShortcut(_ event: NSEvent) {
        guard let direction = recordingShortcut else { return }
        if event.keyCode == 53 { recordingShortcut = nil; shortcutMessage = nil; return }
        let key = PagingKey(event: event)
        if key.isReserved {
            shortcutMessage = "这个按键用于界面操作，请换一个按键。"
            return
        }
        let other: PageDirection = direction == .previous ? .next : .previous
        if key.conflicts(with: pagingShortcuts[other]) {
            shortcutMessage = "这个快捷键已用于\(other.rawValue)，请换一个。"
            return
        }
        pagingShortcuts[direction] = key
        recordingShortcut = nil
        shortcutMessage = "已保存：\(direction.rawValue) \(key.display)"
    }

    func navigate(_ range: NSRange, highlight: Bool = false) {
        guard let book else { return }
        let length = (book.text as NSString).length
        let safe = NSRange(location: min(max(0, range.location), length), length: min(range.length, length - min(max(0, range.location), length)))
        currentPosition = safe.location
        jump = JumpRequest(range: safe, highlight: highlight)
        panel = nil
    }

    func adjacentChapter(_ direction: Int) {
        guard let book else { return }
        let index = min(book.chapters.count - 1, max(0, book.chapterIndex(at: currentPosition) + direction))
        navigate(NSRange(location: book.chapters[index].location, length: 0))
    }

    func updatePosition(_ position: Int, progress: Double) {
        currentPosition = position
        self.progress = progress
        UserDefaults.standard.set(position, forKey: "readingPosition")
        UserDefaults.standard.set(progress, forKey: "readingProgress")
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: "appearance")
        }
    }

    private func search() {
        searchTask?.cancel()
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let book, !value.isEmpty else {
            searchResults = []
            searchTotal = 0
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            let job = Task.detached(priority: .userInitiated) { BookSearch.find(value, in: book) }
            let response = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
            guard !Task.isCancelled else { return }
            searchResults = response.results
            searchTotal = response.total
            isSearching = false
        }
    }
}

extension NSColor {
    static func isValidHex(_ hex: String) -> Bool {
        hex.count == 6 && UInt32(hex, radix: 16) != nil
    }
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x383D44
        self.init(srgbRed: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
