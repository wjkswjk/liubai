#if STANDALONE_TESTS
import Foundation
class XCTestCase {}
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    guard lhs == rhs else { fatalError("Expected \(rhs), got \(lhs)", file: file, line: line) }
}
func XCTAssertTrue(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    guard condition else { fatalError("Expected true", file: file, line: line) }
}
func XCTAssertFalse(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    guard !condition else { fatalError("Expected false", file: file, line: line) }
}
#else
import XCTest
@testable import Liubai
#endif
import AppKit

@MainActor
final class BookTests: XCTestCase {
    func testChineseChaptersAndUTF16Offsets() {
        let book = Book(title: "测试", text: "书名😀\r\n\r\n第一章 初见\r\n文字\r\n第二章 重逢\r\n结尾")
        XCTAssertEqual(book.chapters.map(\.title), ["开篇", "第一章 初见", "第二章 重逢"])
        let source = book.text as NSString
        for chapter in book.chapters where chapter.isHeading {
            XCTAssertEqual(source.substring(with: NSRange(location: chapter.location, length: chapter.length)), chapter.title)
        }
        XCTAssertEqual(book.chapterIndex(at: source.range(of: "结尾").location), 2)
        XCTAssertFalse(book.text.contains("\r"))
    }

    func testCommonHeadingFormats() {
        let text = "序章\n文字\n第001章：开始\n文字\n第三十八回 相遇\n文字\nChapter 4 — Home\n文字\nPART II\n文字\n后记\n文字"
        let book = Book(title: "目录", text: text)
        XCTAssertEqual(book.chapters.count, 6)
        XCTAssertEqual(book.chapters.last?.title, "后记")
    }

    func testProseIsNotMistakenForChapters() {
        let book = Book(title: "散文", text: "第一天，我们出门了。\n章节是阅读的路标。\n一个普通的段落。")
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertFalse(book.chapters[0].isHeading)
    }

    func testEmptyAndNoChapterBooks() {
        let empty = Book(title: "空", text: "")
        XCTAssertEqual(empty.chapters.first?.title, "正文")
        let book = Book(title: "短文", text: "一段文字\n另一段文字")
        XCTAssertEqual(book.chapters.first?.location, 0)
        XCTAssertEqual(book.chapterIndex(at: 999), 0)
    }

    func testUTF8AndUTF16Decoding() throws {
        let text = "第一章 你好\n中文😀"
        XCTAssertEqual(try Book.decode(Data(text.utf8)), text)
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try Book.decode(data).replacingOccurrences(of: "\u{FEFF}", with: ""), text)
    }

    func testGB18030Decoding() throws {
        // GBK bytes for 中文, also valid GB18030.
        XCTAssertEqual(try Book.decode(Data([0xD6, 0xD0, 0xCE, 0xC4])), "中文")
    }

    func testSearchJumpsToExactTextIncludingEmoji() {
        let book = Book(title: "查找", text: "第一章 早晨\n😀山里有风。\n第二章 夜晚\n山里有灯。")
        let result = BookSearch.find("山里", in: book)
        XCTAssertEqual(result.total, 2)
        XCTAssertEqual(result.results.map(\.chapter), ["第一章 早晨", "第二章 夜晚"])
        for hit in result.results {
            XCTAssertEqual((book.text as NSString).substring(with: hit.range), "山里")
        }
    }

    func testSearchLimitKeepsTrueTotal() {
        let book = Book(title: "多结果", text: String(repeating: "风 ", count: 500))
        let result = BookSearch.find("风", in: book, limit: 3)
        XCTAssertEqual(result.total, 500)
        XCTAssertEqual(result.results.count, 3)
        XCTAssertEqual(BookSearch.find("", in: book).total, 0)
        XCTAssertEqual(BookSearch.find("雨", in: book).total, 0)
    }

    func testSearchIsCaseInsensitiveAndHandlesComposedCharacters() {
        let book = Book(title: "英文", text: String(repeating: "😀", count: 30) + "HELLO hello e\u{301}")
        let results = BookSearch.find("hello", in: book)
        XCTAssertEqual(results.total, 2)
        XCTAssertFalse(results.results[0].before.contains("\u{FFFD}"))
    }

    func testBookRoundTripPreservesIndex() throws {
        let book = Book.sample
        let result = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(book, result)
        XCTAssertEqual(book.chapters.filter(\.isHeading).count, 4)
    }

    func testPreferencesSanitizeInvalidData() {
        var preferences = ReaderPreferences()
        preferences.fontSize = 900
        preferences.lineSpacing = -40
        preferences.margin = .infinity
        preferences.background = "not-a-color"
        preferences.sanitize()
        XCTAssertEqual(preferences.fontSize, 48)
        XCTAssertEqual(preferences.lineSpacing, 2)
        XCTAssertEqual(preferences.margin, 48)
        XCTAssertEqual(preferences.background, "F7F8FA")
    }

    func testLegacyPreferencesKeepAppearanceWhenAddingTransparency() throws {
        let data = Data(#"{"fontName":"PingFang SC","fontSize":28,"lineSpacing":8,"margin":32,"background":"1D2026","foreground":"C6CAD1"}"#.utf8)
        let preferences = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        XCTAssertEqual(preferences.fontName, "PingFang SC")
        XCTAssertEqual(preferences.fontSize, 28)
        XCTAssertEqual(preferences.background, "1D2026")
        XCTAssertEqual(preferences.foreground, "C6CAD1")
        XCTAssertEqual(preferences.backgroundOpacity, 1)
    }

    func testBackgroundTransparencyPersists() throws {
        var preferences = ReaderPreferences()
        preferences.backgroundOpacity = 0.35
        preferences.fontSize = 26
        let restored = try JSONDecoder().decode(ReaderPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.readingBackground.alphaComponent, 0.35)
        preferences.backgroundOpacity = 0
        XCTAssertEqual(preferences.readingBackground.alphaComponent, 0)
    }

    func testTransparencyKeepsTextOpaqueAndDoesNotReflow() {
        var preferences = ReaderPreferences()
        let original = preferences
        preferences.backgroundOpacity = 0.5
        preferences.background = "1D2026"
        XCTAssertEqual(preferences.readingBackground.alphaComponent, 0.5)
        XCTAssertEqual(NSColor(hex: preferences.foreground).alphaComponent, 1)
        XCTAssertTrue(preferences.hasSameTextStyle(as: original))
        preferences.fontSize = 30
        XCTAssertFalse(preferences.hasSameTextStyle(as: original))
    }

    func testTransparencyBoundsAndInvalidValues() {
        var preferences = ReaderPreferences()
        preferences.backgroundOpacity = -0.5
        preferences.sanitize()
        XCTAssertEqual(preferences.backgroundOpacity, 0)
        preferences.backgroundOpacity = 2
        preferences.sanitize()
        XCTAssertEqual(preferences.backgroundOpacity, 1)
        preferences.backgroundOpacity = .nan
        preferences.sanitize()
        XCTAssertEqual(preferences.backgroundOpacity, 1)
    }

    func testNativeTextWrapsWhenWidthChanges() {
        let storage = NSTextStorage(string: String(repeating: "窗口变窄时，文字应该自动换行。", count: 12),
                                    attributes: [.font: NSFont.systemFont(ofSize: 22)])
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: 100_000))
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let wide = manager.usedRect(for: container)
        container.containerSize.width = 240
        manager.ensureLayout(for: container)
        let narrow = manager.usedRect(for: container)
        XCTAssertTrue(narrow.height > wide.height)
        XCTAssertTrue(narrow.width <= 240)
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 36), range: NSRange(location: 0, length: storage.length))
        manager.ensureLayout(for: container)
        XCTAssertTrue(manager.usedRect(for: container).height > narrow.height)
    }

    func testShortcutMatchingIgnoresCapsLockAndFunctionFlags() {
        let key = PagingKey(keyCode: 38, flags: [.command, .shift], name: "J")
        XCTAssertTrue(key.matches(keyCode: 38, flags: [.command, .shift, .capsLock, .function]))
        XCTAssertFalse(key.matches(keyCode: 38, flags: [.command]))
        XCTAssertFalse(key.matches(keyCode: 40, flags: [.command, .shift]))
        XCTAssertEqual(key.display, "⇧⌘J")
    }

    func testShortcutConflictsAndReservedCommands() {
        let key = PagingKey(keyCode: 38, name: "J")
        XCTAssertFalse(key.isReserved)
        XCTAssertTrue(PagingKey(keyCode: 3, flags: .command, name: "F").isReserved)
        XCTAssertTrue(PagingKey(keyCode: 53, name: "退出键").isReserved)
        XCTAssertFalse(PagingKey(keyCode: 3, name: "F").isReserved)
        var shortcuts = PagingShortcuts()
        XCTAssertTrue(shortcuts.isValid)
        shortcuts.previous = key
        shortcuts.next = key
        XCTAssertFalse(shortcuts.isValid)
        shortcuts.next = PagingKey(keyCode: 38, flags: .shift, name: "J")
        XCTAssertTrue(shortcuts.isValid)
    }

    func testPagingShortcutsPersistAndDefaultKeys() throws {
        var shortcuts = PagingShortcuts()
        XCTAssertEqual(shortcuts.previous.keyCode, 116)
        XCTAssertEqual(shortcuts.next.keyCode, 121)
        shortcuts.next = PagingKey(keyCode: 40, flags: .option, name: "K")
        let restored = try JSONDecoder().decode(PagingShortcuts.self, from: JSONEncoder().encode(shortcuts))
        XCTAssertEqual(restored, shortcuts)
        XCTAssertTrue(restored.next.matches(keyCode: 40, flags: .option))
    }

    func testPagingOverlapAndDocumentBoundaries() {
        XCTAssertEqual(PagingGeometry.target(current: 0, viewport: 700, document: 5000, direction: .next, overlap: 34), 666)
        XCTAssertEqual(PagingGeometry.target(current: 666, viewport: 700, document: 5000, direction: .previous, overlap: 34), 0)
        XCTAssertEqual(PagingGeometry.target(current: 4200, viewport: 700, document: 5000, direction: .next, overlap: 34), 4300)
        XCTAssertEqual(PagingGeometry.target(current: 0, viewport: 700, document: 300, direction: .next, overlap: 34), 0)
        XCTAssertEqual(PagingGeometry.target(current: 0, viewport: 20, document: 5000, direction: .next, overlap: 34), 10)
    }

    func testBorderlessResizePreservesOppositeEdgesAndMinimumSize() {
        let frame = NSRect(x: 100, y: 100, width: 900, height: 740)
        let minimum = NSSize(width: 360, height: 280)
        let edges: ResizeEdges = [.left, .bottom]
        let small = edges.resizedFrame(from: frame, delta: NSPoint(x: 800, y: 700), minimum: minimum)
        XCTAssertEqual(small.size, minimum)
        XCTAssertEqual(small.maxX, frame.maxX)
        XCTAssertEqual(small.maxY, frame.maxY)
        let large = ResizeEdges([.right, .top]).resizedFrame(from: frame, delta: NSPoint(x: 200, y: 200), minimum: minimum)
        XCTAssertEqual(large.origin, frame.origin)
        XCTAssertEqual(large.size, NSSize(width: 1100, height: 940))
    }

    func testBorderlessResizeHitTargets() {
        let size = NSSize(width: 900, height: 740)
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 2, y: 2), size: size), [.left, .bottom])
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 899, y: 739), size: size), [.right, .top])
        XCTAssertTrue(ResizeEdges.hitTest(NSPoint(x: 450, y: 350), size: size).isEmpty)
    }

    func testTransparentEdgesHaveMinimumMouseCoverage() {
        let required = WindowInteractionRegions.hitAlpha(over: 0)
        XCTAssertTrue(required > 0)
        XCTAssertTrue(required <= 0.02)
        let partial: CGFloat = 0.01
        let combined = partial + (1 - partial) * WindowInteractionRegions.hitAlpha(over: partial)
        XCTAssertTrue(abs(combined - WindowInteractionRegions.minimumHitAlpha) < 0.000001)
        XCTAssertEqual(WindowInteractionRegions.hitAlpha(over: 0.5), 0)
        XCTAssertEqual(WindowInteractionRegions.hitAlpha(over: 1), 0)
    }

    func testInteractionAreaCoversTransparentBlankSpace() {
        let size = NSSize(width: 900, height: 740)
        let path = WindowInteractionRegions.responsePath(in: NSRect(origin: .zero, size: size))
        for point in [NSPoint(x: 5, y: 350), NSPoint(x: 895, y: 350),
                      NSPoint(x: 450, y: 5), NSPoint(x: 450, y: 735), NSPoint(x: 450, y: 720)] {
            XCTAssertTrue(path.contains(point))
        }
        XCTAssertTrue(path.contains(NSPoint(x: 450, y: 350)))
        XCTAssertTrue(WindowInteractionRegions.isDragArea(NSPoint(x: 450, y: 720), size: size))
        XCTAssertFalse(WindowInteractionRegions.isDragArea(NSPoint(x: 5, y: 720), size: size))
    }

    func testPagesCoverEveryLineWithoutClippingOrSkipping() {
        let lines = (0..<97).map { index in
            ReadingLine(rect: NSRect(x: 0, y: 64 + index * 37, width: 200, height: 37),
                        characters: NSRange(location: index * 10, length: 10))
        }
        for height: CGFloat in [280, 413, 740] {
            var seen: [Int] = []
            var origin: CGFloat = 0
            for _ in 0..<100 {
                let visible = ReadingPageGeometry.visibleLines(lines, origin: origin, height: height)
                for index in visible {
                    XCTAssertTrue(lines[index].rect.minY >= origin + ReadingPageGeometry.top - 0.5)
                    XCTAssertTrue(lines[index].rect.maxY <= origin + height - ReadingPageGeometry.bottom + 0.5)
                    seen.append(index)
                }
                let next = ReadingPageGeometry.nextOrigin(lines, origin: origin, height: height)
                if next == origin { break }
                origin = next
            }
            XCTAssertEqual(seen, Array(0..<97))
        }
        XCTAssertEqual(ReadingPageGeometry.previousOrigin(lines, origin: 0, height: 280), 0)
    }

    private func readerFixture(bookText: String? = nil) -> (ReaderView.Coordinator, ReadingScrollView, ReadingTextView) {
        let model = ReaderModel()
        model.preferences = ReaderPreferences()
        model.book = Book(title: "缩放回归", text: bookText ?? (0..<100).map { "第\($0)行：窗口变窄时，所有文字都应重新换行并完整显示。😀" }.joined(separator: "\n"))
        let scroll = ReadingScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 740))
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let text = ReadingTextView(frame: scroll.bounds, textContainer: container)
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.autoresizingMask = []
        scroll.documentView = text
        let coordinator = ReaderView.Coordinator(model: model)
        coordinator.scroll = scroll
        coordinator.text = text
        coordinator.update()
        return (coordinator, scroll, text)
    }

    func testActualReaderLayoutReflowsAndUpdatesHeightOnRepeatedResize() {
        let (coordinator, scroll, text) = readerFixture()
        defer { coordinator.removeObserver() }
        let widePageLength = coordinator.nextPosition
        coordinator.turnPage(.next)
        let before = coordinator.visiblePosition()
        for size in [NSSize(width: 360, height: 280), NSSize(width: 520, height: 500),
                     NSSize(width: 240, height: 160), NSSize(width: 360, height: 420), NSSize(width: 900, height: 740)] {
            scroll.setFrameSize(size)
            coordinator.resize(scroll.contentSize)
            let manager = text.layoutManager!
            let container = text.textContainer!
            manager.ensureLayout(for: container)
            XCTAssertTrue(manager.usedRect(for: container).maxX <= container.containerSize.width + 0.5)
            // TextKit's extra empty fragment after a trailing newline is not a
            // displayed glyph line; check the last actual line instead.
            XCTAssertTrue(coordinator.lines.last!.rect.maxY <= scroll.contentSize.height - ReadingPageGeometry.bottom + 0.5)
            XCTAssertEqual(text.frame.width, scroll.contentSize.width)
            if size.width <= 360 { XCTAssertTrue(coordinator.nextPosition - coordinator.anchor < widePageLength) }
            XCTAssertTrue(abs(coordinator.visiblePosition() - before) < 70)
            let visible = ReadingPageGeometry.visibleLines(coordinator.lines, origin: scroll.contentView.bounds.minY,
                height: scroll.contentSize.height)
            XCTAssertFalse(visible.isEmpty)
            XCTAssertTrue(text.completeLinesRect!.height > 0)
        }
        XCTAssertEqual(coordinator.lines.last!.characters.upperBound, (text.string as NSString).length)
    }

    func testNativePagingChangesBoundsImmediatelyAndReturnsToOriginalPage() {
        let (coordinator, scroll, text) = readerFixture()
        defer { coordinator.removeObserver() }
        let initial = scroll.contentView.bounds.origin
        let initialText = text.string
        let end = coordinator.nextPosition
        coordinator.turnPage(.next)
        XCTAssertEqual(coordinator.anchor, end)
        XCTAssertFalse(text.string == initialText)
        XCTAssertEqual(scroll.contentView.bounds.origin, initial)
        XCTAssertEqual(coordinator.pageHistory, [0])
        coordinator.turnPage(.previous)
        XCTAssertEqual(scroll.contentView.bounds.origin, initial)
        XCTAssertTrue(coordinator.pageHistory.isEmpty)
        XCTAssertEqual(text.string, initialText)
    }

    func testNativePagesPreserveWholeBookAndUnicodeBoundaries() {
        let (coordinator, scroll, text) = readerFixture()
        defer { coordinator.removeObserver() }
        scroll.setFrameSize(NSSize(width: 240, height: 160))
        coordinator.resize(scroll.contentSize)
        var collected = ""
        for _ in 0..<5000 {
            collected += text.string
            XCTAssertFalse(text.string.contains("\u{FFFD}"))
            XCTAssertTrue(coordinator.nextPosition > coordinator.anchor)
            if coordinator.nextPosition == coordinator.source.length { break }
            coordinator.turnPage(.next)
        }
        XCTAssertEqual(collected, coordinator.source.string)
        let final = coordinator.anchor
        coordinator.turnPage(.next)
        XCTAssertEqual(coordinator.anchor, final)
    }

    func testSearchHighlightUsesGlobalPositionAfterPaging() {
        let (coordinator, scroll, text) = readerFixture()
        defer { coordinator.removeObserver() }
        let match = (coordinator.source.string as NSString).range(of: "第95行")
        coordinator.scrollTo(match, highlight: true)
        XCTAssertEqual(coordinator.anchor, match.location)
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "第95行")
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    func testLargestFontStillFitsSmallestWindow() {
        let (coordinator, scroll, text) = readerFixture()
        defer { coordinator.removeObserver() }
        coordinator.model.preferences.fontSize = 48
        coordinator.model.preferences.lineSpacing = 30
        scroll.setFrameSize(ReaderWindow.minimumReadingSize)
        coordinator.update()
        XCTAssertFalse(text.string.isEmpty)
        XCTAssertTrue(coordinator.lines.last!.rect.maxY <= scroll.contentSize.height - ReadingPageGeometry.bottom + 0.5)
    }

    func testPageCacheIsBoundedAndInvalidatesOnResize() {
        let (coordinator, scroll, text) = readerFixture()
        defer { coordinator.removeObserver() }
        let first = text.string
        coordinator.turnPage(.next)
        coordinator.turnPage(.previous)
        XCTAssertEqual(text.string, first)
        XCTAssertTrue(coordinator.cacheHits > 0)
        scroll.setFrameSize(NSSize(width: 240, height: 160))
        coordinator.resize(scroll.contentSize)
        XCTAssertEqual(coordinator.cachedPageCount, 1)
        for _ in 0..<25 { coordinator.turnPage(.next) }
        XCTAssertEqual(coordinator.cachedPageCount, 16)
        coordinator.model.preferences.fontSize = 30
        coordinator.update()
        XCTAssertEqual(coordinator.cachedPageCount, 1)
        XCTAssertTrue(coordinator.lines.last!.rect.maxY <= scroll.contentSize.height - ReadingPageGeometry.bottom + 0.5)
    }

    func testChangingColorPreservesPagesHistoryAndCachedTextColor() {
        let (coordinator, _, text) = readerFixture()
        defer { coordinator.removeObserver() }
        let first = text.string
        coordinator.turnPage(.next)
        let position = coordinator.anchor
        let boundary = coordinator.nextPosition
        let cached = coordinator.cachedPageCount
        coordinator.model.preferences.foreground = "CC4433"
        coordinator.update()
        XCTAssertEqual(coordinator.anchor, position)
        XCTAssertEqual(coordinator.nextPosition, boundary)
        XCTAssertEqual(coordinator.cachedPageCount, cached)
        XCTAssertEqual(coordinator.pageHistory, [0])
        coordinator.turnPage(.previous)
        XCTAssertEqual(text.string, first)
        let color = text.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        XCTAssertEqual(color.hex, "CC4433")
    }

    func testImmediateQuitFlushesLatestPagePosition() {
        let (coordinator, _, _) = readerFixture()
        defer { coordinator.removeObserver() }
        coordinator.turnPage(.next)
        coordinator.model.finishReading()
        XCTAssertEqual(coordinator.model.currentPosition, coordinator.anchor)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "readingPosition"), coordinator.anchor)
        let position = coordinator.model.currentPosition
        coordinator.model.bookID = UUID()
        coordinator.model.flushPosition()
        XCTAssertEqual(coordinator.model.currentPosition, position)
    }

    func testRestoredBookStartsAtSavedPageBeforeRendering() {
        let (coordinator, _, text) = readerFixture()
        defer { coordinator.removeObserver() }
        coordinator.turnPage(.next)
        let position = coordinator.anchor
        let expected = text.string
        let book = coordinator.model.book!
        coordinator.model.present(book, persist: false, startingAt: position, progress: 0.3)
        XCTAssertEqual(coordinator.model.jump!.range.location, position)
        coordinator.update()
        XCTAssertEqual(coordinator.anchor, position)
        XCTAssertEqual(text.string, expected)
    }

    func testSavedPositionSurvivesInitialZeroSizeViewport() {
        let (coordinator, scroll, text) = readerFixture()
        defer { coordinator.removeObserver() }
        let position = (coordinator.source.string as NSString).range(of: "第70行").location
        scroll.setFrameSize(.zero)
        coordinator.model.present(coordinator.model.book!, persist: false, startingAt: position)
        coordinator.update()
        XCTAssertEqual(coordinator.anchor, position)
        scroll.setFrameSize(NSSize(width: 520, height: 500))
        coordinator.resize(scroll.contentSize)
        XCTAssertEqual(coordinator.anchor, position)
        XCTAssertTrue(text.string.hasPrefix("第70行"))
    }

    func testPanelExpandsWithinScreenAndLeavesLargeWindowUnchanged() {
        let visible = NSRect(x: 200, y: 100, width: 1440, height: 900)
        let tiny = NSRect(x: 1500, y: 120, width: 240, height: 160)
        let expanded = PanelWindowGeometry.expandedFrame(from: tiny, within: visible)
        XCTAssertEqual(expanded.size, NSSize(width: 560, height: 580))
        XCTAssertTrue(visible.contains(expanded))
        let large = NSRect(x: 300, y: 200, width: 900, height: 740)
        XCTAssertEqual(PanelWindowGeometry.expandedFrame(from: large, within: visible), large)
    }

    func testTrackpadTurnsOncePerGestureAndIgnoresMomentum() {
        var gesture = PagingScrollGesture()
        XCTAssertEqual(gesture.direction(delta: -1, phase: .began, momentum: [], precise: true), nil)
        XCTAssertEqual(gesture.direction(delta: -3, phase: .changed, momentum: [], precise: true), nil)
        XCTAssertEqual(gesture.direction(delta: -5, phase: .changed, momentum: [], precise: true), .next)
        XCTAssertEqual(gesture.direction(delta: -30, phase: .changed, momentum: [], precise: true), nil)
        XCTAssertEqual(gesture.direction(delta: -30, phase: [], momentum: .began, precise: true), nil)
        XCTAssertEqual(gesture.direction(delta: 0, phase: .ended, momentum: [], precise: true), nil)
        XCTAssertEqual(gesture.direction(delta: 12, phase: .began, momentum: [], precise: true), .previous)
        XCTAssertEqual(gesture.direction(delta: 0, phase: .cancelled, momentum: [], precise: true), nil)
        XCTAssertEqual(gesture.direction(delta: -1, phase: [], momentum: [], precise: false), .next)
        XCTAssertEqual(gesture.direction(delta: -1, phase: [], momentum: [], precise: false), .next)
    }

    func testSpaceAndShiftSpaceTurnPages() {
        let text = ReadingTextView()
        var directions: [PageDirection] = []
        text.turnPage = { directions.append($0) }
        for flags: NSEvent.ModifierFlags in [[], .shift] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49)!
            text.keyDown(with: event)
        }
        XCTAssertEqual(directions, [.next, .previous])
    }

    func benchmarkReading() {
        let large = String(repeating: "山里的早晨安静而清凉，文字应当随窗口自动换行，翻页立即切换。\n", count: 50_000)
        let start = Date.timeIntervalSinceReferenceDate
        let (coordinator, _, _) = readerFixture(bookText: large)
        defer { coordinator.removeObserver() }
        let opened = Date.timeIntervalSinceReferenceDate
        for _ in 0..<100 { coordinator.turnPage(.next); coordinator.turnPage(.previous) }
        let ended = Date.timeIntervalSinceReferenceDate
        print(String(format: "基准：%.2f MB，首次准备 %.1f ms，往返翻页平均 %.2f ms/页",
            Double(large.utf8.count) / 1_000_000, (opened - start) * 1000, (ended - opened) * 1000 / 200))
    }

    func testWiderResizeBandAndAllCorners() {
        let size = NSSize(width: 900, height: 740)
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 9, y: 350), size: size), .left)
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 891, y: 350), size: size), .right)
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 9, y: 9), size: size), [.left, .bottom])
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 9, y: 731), size: size), [.left, .top])
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 891, y: 9), size: size), [.right, .bottom])
        XCTAssertEqual(ResizeEdges.hitTest(NSPoint(x: 891, y: 731), size: size), [.right, .top])
        XCTAssertTrue(ResizeEdges.hitTest(NSPoint(x: -5, y: 350), size: size).isEmpty)
        XCTAssertTrue(ResizeEdges.hitTest(NSPoint(x: 450, y: 350), size: size).isEmpty)
    }
}

#if STANDALONE_TESTS
@main
@MainActor
enum TestRunner {
    static func main() async throws {
        let tests = BookTests()
        if CommandLine.arguments.contains("--benchmark") { tests.benchmarkReading(); return }
        tests.testChineseChaptersAndUTF16Offsets()
        tests.testCommonHeadingFormats()
        tests.testProseIsNotMistakenForChapters()
        tests.testEmptyAndNoChapterBooks()
        try tests.testUTF8AndUTF16Decoding()
        try tests.testGB18030Decoding()
        tests.testSearchJumpsToExactTextIncludingEmoji()
        tests.testSearchLimitKeepsTrueTotal()
        tests.testSearchIsCaseInsensitiveAndHandlesComposedCharacters()
        try tests.testBookRoundTripPreservesIndex()
        tests.testPreferencesSanitizeInvalidData()
        try tests.testLegacyPreferencesKeepAppearanceWhenAddingTransparency()
        try tests.testBackgroundTransparencyPersists()
        tests.testTransparencyKeepsTextOpaqueAndDoesNotReflow()
        tests.testTransparencyBoundsAndInvalidValues()
        tests.testNativeTextWrapsWhenWidthChanges()
        tests.testShortcutMatchingIgnoresCapsLockAndFunctionFlags()
        tests.testShortcutConflictsAndReservedCommands()
        try tests.testPagingShortcutsPersistAndDefaultKeys()
        tests.testPagingOverlapAndDocumentBoundaries()
        tests.testBorderlessResizePreservesOppositeEdgesAndMinimumSize()
        tests.testBorderlessResizeHitTargets()
        tests.testTransparentEdgesHaveMinimumMouseCoverage()
        tests.testInteractionAreaCoversTransparentBlankSpace()
        tests.testWiderResizeBandAndAllCorners()
        tests.testPagesCoverEveryLineWithoutClippingOrSkipping()
        tests.testActualReaderLayoutReflowsAndUpdatesHeightOnRepeatedResize()
        tests.testNativePagingChangesBoundsImmediatelyAndReturnsToOriginalPage()
        tests.testNativePagesPreserveWholeBookAndUnicodeBoundaries()
        tests.testSearchHighlightUsesGlobalPositionAfterPaging()
        tests.testLargestFontStillFitsSmallestWindow()
        tests.testPageCacheIsBoundedAndInvalidatesOnResize()
        tests.testChangingColorPreservesPagesHistoryAndCachedTextColor()
        tests.testImmediateQuitFlushesLatestPagePosition()
        tests.testRestoredBookStartsAtSavedPageBeforeRendering()
        tests.testSavedPositionSurvivesInitialZeroSizeViewport()
        tests.testPanelExpandsWithinScreenAndLeavesLargeWindowUnchanged()
        tests.testTrackpadTurnsOncePerGestureAndIgnoresMomentum()
        tests.testSpaceAndShiftSpaceTurnPages()
        let listening = ListeningTests()
        listening.testLongBookChunksCoverUnicodeAndCrossChapters()
        listening.testEscapingAndByteLimitForXMLHeavyText()
        try listening.testAudioFramesRejectTruncationAndAcceptEndMarker()
        listening.testTokenAndSSMLMatchServiceContract()
        try await listening.testAudioCacheReusesTextAndSeparatesVoices()
        try await listening.testPauseWhileLoadingPreservesResumeTimeAndBookmark()
        try await listening.testStopAndBookChangeCancelLoadingWithoutStaleCallbacks()
        print("46 项测试通过：阅读与分页、Edge 语音协议、长文本切分、音频缓存、听书进度与取消。")
    }
}
#endif
