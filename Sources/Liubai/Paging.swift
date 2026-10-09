import AppKit

enum PageDirection: String, CaseIterable, Identifiable {
    case previous = "上一页", next = "下一页"
    var id: String { rawValue }
    var sign: CGFloat { self == .next ? 1 : -1 }
}

struct PageRequest {
    let id = UUID()
    let direction: PageDirection
}

struct PagingKey: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let name: String

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags = [], name: String) {
        self.keyCode = keyCode
        self.modifiers = flags.intersection(Self.relevantModifiers).rawValue
        self.name = name
    }

    init(event: NSEvent) {
        self.init(keyCode: event.keyCode, flags: event.modifierFlags,
                  name: Self.keyName(event.keyCode, characters: event.charactersIgnoringModifiers))
    }

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "") +
            (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") +
            (flags.contains(.command) ? "⌘" : "") + name
    }

    func matches(_ event: NSEvent) -> Bool {
        matches(keyCode: event.keyCode, flags: event.modifierFlags)
    }

    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && modifiers == flags.intersection(Self.relevantModifiers).rawValue
    }

    func conflicts(with other: PagingKey) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    var isReserved: Bool {
        if [36, 48, 53, 76].contains(keyCode) { return true }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags == .command && [0, 3, 4, 6, 7, 8, 9, 12, 13, 17, 24, 27, 31, 43, 46].contains(keyCode) { return true }
        if flags == [.command, .shift] && [6, 24, 43, 44].contains(keyCode) { return true }
        if flags == [.command, .control] && keyCode == 3 { return true }
        if flags == [.command, .option] && [4, 123, 124].contains(keyCode) { return true }
        return name.isEmpty
    }

    static func keyName(_ code: UInt16, characters: String?) -> String {
        let names: [UInt16: String] = [
            36: "回车", 48: "制表键", 49: "空格", 51: "删除", 53: "退出键", 71: "清除",
            76: "回车", 115: "行首键", 116: "上一页键", 117: "向前删除", 119: "行尾键", 121: "下一页键",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        return names[code] ?? characters?.uppercased() ?? ""
    }
}

struct PagingShortcuts: Codable, Equatable {
    var previous = PagingKey(keyCode: 116, name: "上一页键")
    var next = PagingKey(keyCode: 121, name: "下一页键")

    subscript(_ direction: PageDirection) -> PagingKey {
        get { direction == .previous ? previous : next }
        set { if direction == .previous { previous = newValue } else { next = newValue } }
    }

    var isValid: Bool { !previous.isReserved && !next.isReserved && !previous.conflicts(with: next) }

    func direction(for event: NSEvent) -> PageDirection? {
        if previous.matches(event) { return .previous }
        if next.matches(event) { return .next }
        return nil
    }
}

enum PagingGeometry {
    static func target(current: CGFloat, viewport: CGFloat, document: CGFloat,
                       direction: PageDirection, overlap: CGFloat) -> CGFloat {
        let distance = max(1, viewport - min(overlap, viewport / 2))
        return min(max(0, document - viewport), max(0, current + direction.sign * distance))
    }
}

struct ReadingLine {
    let rect: NSRect
    let characters: NSRange
}

enum ReadingPageGeometry {
    static let top: CGFloat = 28
    static let bottom: CGFloat = 24

    static func visibleLines(_ lines: [ReadingLine], origin: CGFloat, height: CGFloat) -> Range<Int> {
        let start = origin + top
        let end = origin + height - bottom
        // Binary search keeps paging fast even for a long book.
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].rect.minY < start - 0.5 { low = mid + 1 } else { high = mid }
        }
        let first = low
        while low < lines.count && lines[low].rect.maxY <= end + 0.5 { low += 1 }
        return first..<low
    }

    static func nextOrigin(_ lines: [ReadingLine], origin: CGFloat, height: CGFloat) -> CGFloat {
        let visible = visibleLines(lines, origin: origin, height: height)
        guard visible.upperBound < lines.count else { return origin }
        return max(0, lines[visible.upperBound].rect.minY - top)
    }

    static func previousOrigin(_ lines: [ReadingLine], origin: CGFloat, height: CGFloat) -> CGFloat {
        let visible = visibleLines(lines, origin: origin, height: height)
        guard visible.lowerBound > 0 else { return 0 }
        let last = min(visible.lowerBound - 1, lines.count - 1)
        let available = height - top - bottom
        var first = last
        while first > 0 && lines[last].rect.maxY - lines[first - 1].rect.minY <= available { first -= 1 }
        return first == 0 ? 0 : max(0, lines[first].rect.minY - top)
    }
}
