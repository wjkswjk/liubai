import AppKit
import SwiftUI
import QuartzCore

final class ReadingTextView: NSTextView {
    var showPanel: (() -> Void)?
    var turnPage: ((PageDirection) -> Void)?
    var completeLinesRect: NSRect?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let completeLinesRect else { super.draw(dirtyRect); return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: completeLinesRect).addClip()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func rightMouseDown(with event: NSEvent) { showPanel?() }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.locationInWindow.y >= (window?.frame.height ?? 0) - WindowInteractionRegions.dragHeight {
            (window as? ReaderWindow)?.trackMove(from: event)
            return
        }
        guard let manager = layoutManager, let container = textContainer else {
            super.mouseDown(with: event)
            return
        }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = manager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let used = glyph < manager.numberOfGlyphs
            ? manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            : .zero
        if event.clickCount == 1 && (!used.insetBy(dx: -8, dy: 0).contains(local) || local.y < 0) {
            (window as? ReaderWindow)?.trackMove(from: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { showPanel?(); return }
        if [116, 126].contains(event.keyCode) { turnPage?(.previous); return }
        if [121, 125].contains(event.keyCode) { turnPage?(.next); return }
        super.keyDown(with: event)
    }
}

final class ReadingScrollView: NSScrollView {
    override var isOpaque: Bool { false }
    var viewportChanged: ((NSSize) -> Void)?
    var turnPage: ((PageDirection) -> Void)?
    private var gestureTurnedPage = false

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) { gestureTurnedPage = false }
        if !gestureTurnedPage && abs(event.scrollingDeltaY) > 0.1 {
            turnPage?(event.scrollingDeltaY < 0 ? .next : .previous)
            gestureTurnedPage = !event.phase.isEmpty
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { gestureTurnedPage = false }
    }
    override func tile() {
        super.tile()
        viewportChanged?(contentSize)
    }

    // Changing pages sets the clip bounds directly; no animator or momentum.
    func showImmediately(at origin: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.setBoundsOrigin(NSPoint(x: 0, y: origin))
        reflectScrolledClipView(contentView)
        contentView.needsDisplay = true
        documentView?.needsDisplay = true
        CATransaction.commit()
    }
}

struct ReaderView: NSViewRepresentable {
    @ObservedObject var model: ReaderModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ReadingScrollView {
        let scroll = ReadingScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .clear
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.autoresizingMask = [.width, .height]
        scroll.contentView.postsBoundsChangedNotifications = true

        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.allowsNonContiguousLayout = false
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        let text = ReadingTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = []
        text.setAccessibilityLabel("阅读正文")
        text.showPanel = { [weak model] in model?.togglePanel() }
        scroll.documentView = text
        context.coordinator.scroll = scroll
        context.coordinator.text = text
        let page: (PageDirection) -> Void = { [weak model] direction in model?.page(direction) }
        scroll.turnPage = page
        text.turnPage = page
        scroll.viewportChanged = { [weak coordinator = context.coordinator] size in coordinator?.resize(size) }
        context.coordinator.observeScroll()
        return scroll
    }

    func updateNSView(_ scroll: ReadingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.update()
    }

    static func dismantleNSView(_ view: ReadingScrollView, coordinator: Coordinator) {
        coordinator.persistPosition()
        coordinator.removeObserver()
    }

    @MainActor
    final class Coordinator {
        var model: ReaderModel
        weak var scroll: ReadingScrollView?
        weak var text: ReadingTextView?
        var previousBook: UUID?
        var previousPreferences: ReaderPreferences?
        var lastJump: UUID?
        var lastPage: UUID?
        var lastViewport: NSSize = .zero
        var source = NSAttributedString(string: "")
        var lines: [ReadingLine] = []
        var anchor = 0
        var nextPosition = 0
        var pageHistory: [Int] = []
        var saveWork: DispatchWorkItem?
        var isUpdating = false
        var isLayingOut = false

        init(model: ReaderModel) { self.model = model }

        func observeScroll() {}
        func removeObserver() { saveWork?.cancel() }

        func update() {
            guard let text, let scroll, let book = model.book else { return }
            let changedBook = previousBook != model.bookID
            let changedStyle = previousPreferences.map { !model.preferences.hasSameTextStyle(as: $0) } ?? true
            isUpdating = true
            defer { isUpdating = false; scheduleSave() }
            if changedBook || changedStyle {
                let prefs = model.preferences
                let style = NSMutableParagraphStyle()
                style.lineSpacing = prefs.lineSpacing
                style.paragraphSpacing = 3
                style.lineBreakMode = .byWordWrapping
                let attributed = NSMutableAttributedString(string: book.text, attributes: [
                    .font: prefs.nsFont, .foregroundColor: NSColor(hex: prefs.foreground), .paragraphStyle: style
                ])
                for chapter in book.chapters where chapter.isHeading && chapter.length > 0 {
                    let heading = style.mutableCopy() as! NSMutableParagraphStyle
                    heading.paragraphSpacingBefore = prefs.fontSize * 0.7
                    heading.paragraphSpacing = prefs.fontSize * 0.4
                    attributed.addAttributes([
                        .font: NSFont(name: prefs.fontName, size: prefs.fontSize * 1.13) ?? prefs.nsFont,
                        .paragraphStyle: heading
                    ], range: NSRange(location: chapter.location, length: chapter.length))
                }
                source = attributed
                text.selectedTextAttributes = [
                    .backgroundColor: NSColor(hex: prefs.foreground).withAlphaComponent(0.17),
                    .foregroundColor: NSColor(hex: prefs.foreground)
                ]
                previousBook = model.bookID
                pageHistory.removeAll()
                renderPage(at: changedBook ? model.currentPosition : anchor, size: scroll.contentSize)
            }
            previousPreferences = model.preferences
            if let jump = model.jump, lastJump != jump.id {
                lastJump = jump.id
                scrollTo(jump.range, highlight: jump.highlight)
            }
            if let request = model.pageRequest, lastPage != request.id {
                lastPage = request.id
                turnPage(request.direction)
            }
            if model.panel == nil, text.window?.firstResponder !== text {
                text.window?.makeFirstResponder(text)
            }
        }

        func resize(_ size: NSSize, keepPosition: Bool = true) {
            guard size.width > 0, size.height > 0, size != lastViewport, !isLayingOut else { return }
            pageHistory.removeAll()
            renderPage(at: keepPosition ? anchor : 0, size: size)
            scheduleSave()
        }

        private func chunkRange(at position: Int, length: Int) -> NSRange {
            let string = source.string as NSString
            let range = NSRange(location: position, length: min(length, source.length - position))
            return string.rangeOfComposedCharacterSequences(for: range)
        }

        private func estimatedChunkSize(_ size: NSSize) -> Int {
            let font = max(12, model.preferences.fontSize)
            return max(2048, Int(size.width / font * size.height / font * 4))
        }

        func renderPage(at position: Int, size: NSSize) {
            guard !isLayingOut, size.width > 0, size.height > 0, source.length > 0,
                  let text, let scroll, let manager = text.layoutManager, let container = text.textContainer else { return }
            isLayingOut = true
            defer { isLayingOut = false }
            lastViewport = size
            let string = source.string as NSString
            let safe = max(0, min(position, source.length - 1))
            anchor = string.rangeOfComposedCharacterSequence(at: safe).location
            let inset = min(CGFloat(model.preferences.margin), max(18, size.width * 0.10))
            text.textContainerInset = NSSize(width: inset, height: ReadingPageGeometry.top)
            container.containerSize = NSSize(width: max(40, size.width - 2 * inset), height: CGFloat.greatestFiniteMagnitude)
            text.setFrameSize(NSSize(width: size.width, height: size.height))
            var chunkLength = estimatedChunkSize(size)
            var pageLength = 0
            while true {
                let range = chunkRange(at: anchor, length: chunkLength)
                let candidate = NSMutableAttributedString(attributedString: source.attributedSubstring(from: range))
                // A heading starting a page does not need space above the page.
                if let style = candidate.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    let firstStyle = style.mutableCopy() as! NSMutableParagraphStyle
                    firstStyle.paragraphSpacingBefore = 0
                    let paragraph = (candidate.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                    candidate.addAttribute(.paragraphStyle, value: firstStyle, range: paragraph)
                }
                text.textStorage?.setAttributedString(candidate)
                manager.ensureLayout(for: container)
                lines.removeAll(keepingCapacity: true)
                manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                    rect, _, _, glyphs, _ in
                    let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    self.lines.append(ReadingLine(rect: rect.offsetBy(dx: inset, dy: ReadingPageGeometry.top), characters: characters))
                }
                let visible = ReadingPageGeometry.visibleLines(lines, origin: 0, height: size.height)
                if visible.upperBound == lines.count && range.upperBound < source.length {
                    chunkLength *= 2
                    continue
                }
                if let last = visible.last { pageLength = lines[last].characters.upperBound }
                else if let first = lines.first { pageLength = first.characters.upperBound }
                break
            }
            nextPosition = min(source.length, anchor + pageLength)
            // Store only the visible page in NSTextView: AppKit cannot scroll or
            // select hidden text, and resizing never lays out the entire book.
            if pageLength < text.textStorage!.length {
                text.textStorage?.deleteCharacters(in: NSRange(location: pageLength, length: text.textStorage!.length - pageLength))
            }
            manager.ensureLayout(for: container)
            lines.removeAll(keepingCapacity: true)
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                rect, _, _, glyphs, _ in
                self.lines.append(ReadingLine(rect: rect.offsetBy(dx: inset, dy: ReadingPageGeometry.top),
                    characters: manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
            }
            scroll.showImmediately(at: 0)
            refreshVisibleLines()
            text.setSelectedRange(NSRange(location: 0, length: 0))
        }

        func visiblePosition() -> Int { anchor }

        func refreshVisibleLines() {
            guard let text else { return }
            if let first = lines.first, let last = lines.last {
                text.completeLinesRect = NSRect(x: 0, y: first.rect.minY, width: text.frame.width,
                    height: last.rect.maxY - first.rect.minY)
            } else { text.completeLinesRect = .zero }
            text.needsDisplay = true
        }

        private func precedingPageStart() -> Int {
            guard anchor > 0, let scroll else { return 0 }
            let size = scroll.contentSize
            let count = min(anchor, estimatedChunkSize(size))
            let range = (source.string as NSString).rangeOfComposedCharacterSequences(
                for: NSRange(location: anchor - count, length: count))
            let storage = NSTextStorage(attributedString: source.attributedSubstring(from: range))
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(containerSize: text?.textContainer?.containerSize ?? size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            var preceding: [ReadingLine] = []
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                rect, _, _, glyphs, _ in
                preceding.append(ReadingLine(rect: rect, characters: manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)))
            }
            guard let last = preceding.last else { return 0 }
            let available = size.height - ReadingPageGeometry.top - ReadingPageGeometry.bottom
            var first = preceding.count - 1
            while first > 0 && last.rect.maxY - preceding[first - 1].rect.minY <= available { first -= 1 }
            return range.location + preceding[first].characters.location
        }

        func turnPage(_ direction: PageDirection) {
            guard let scroll else { return }
            if direction == .next {
                guard nextPosition < source.length, nextPosition > anchor else { return }
                pageHistory.append(anchor)
                renderPage(at: nextPosition, size: scroll.contentSize)
            } else {
                guard anchor > 0 else { return }
                renderPage(at: pageHistory.popLast() ?? precedingPageStart(), size: scroll.contentSize)
            }
            scheduleSave()
        }

        func scrollTo(_ range: NSRange, highlight: Bool) {
            guard let text, let scroll, source.length > 0 else { return }
            pageHistory.removeAll()
            renderPage(at: range.location, size: scroll.contentSize)
            let local = max(0, range.location - anchor)
            let length = min(range.length, max(0, nextPosition - anchor - local))
            if highlight { text.setSelectedRange(NSRange(location: local, length: length)) }
            scheduleSave()
        }

        func scheduleSave() {
            guard !isUpdating else { return }
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.persistPosition() }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func persistPosition() {
            guard previousBook == model.bookID, source.length > 0 else { return }
            let progress = nextPosition >= source.length ? 1 : Double(anchor) / Double(source.length)
            model.updatePosition(anchor, progress: progress)
        }
    }
}
