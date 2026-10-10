import AppKit
import SwiftUI

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

enum WindowInteractionRegions {
    static let edgeWidth: CGFloat = 10
    static let dragHeight: CGFloat = 28
    static let minimumHitAlpha: CGFloat = 0.02

    static func hitAlpha(over backgroundOpacity: CGFloat) -> CGFloat {
        let opacity = min(1, max(0, backgroundOpacity))
        guard opacity < minimumHitAlpha else { return 0 }
        return (minimumHitAlpha - opacity) / (1 - opacity)
    }

    static func isDragArea(_ point: NSPoint, size: NSSize) -> Bool {
        ResizeEdges.hitTest(point, size: size).isEmpty && point.y >= size.height - dragHeight &&
            NSRect(origin: .zero, size: size).contains(point)
    }

    static func responsePath(in bounds: NSRect) -> NSBezierPath {
        NSBezierPath(rect: bounds)
    }
}

// A zero-alpha pixel passes mouse input to the application behind this window.
// Cover the whole surface very faintly so blank-space clicks also stay here.
final class WindowInteractionView: NSView {
    var backgroundOpacity: CGFloat = 1 { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard window?.styleMask.contains(.fullScreen) != true else { return }
        let alpha = WindowInteractionRegions.hitAlpha(over: backgroundOpacity)
        guard alpha > 0 else { return }
        NSColor(calibratedWhite: 0.5, alpha: alpha).setFill()
        WindowInteractionRegions.responsePath(in: bounds).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard window?.styleMask.contains(.fullScreen) != true, window?.attachedSheet == nil else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return !ResizeEdges.hitTest(local, size: bounds.size).isEmpty ||
            WindowInteractionRegions.isDragArea(local, size: bounds.size) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let edges = ResizeEdges.hitTest(event.locationInWindow, size: window.frame.size)
        if !edges.isEmpty, let readerWindow = window as? ReaderWindow {
            readerWindow.trackResize(from: event, edges: edges)
        } else if let readerWindow = window as? ReaderWindow {
            readerWindow.trackMove(from: event)
        }
    }

    override func resetCursorRects() {
        guard window?.styleMask.contains(.fullScreen) != true, window?.attachedSheet == nil else { return }
        let edge = WindowInteractionRegions.edgeWidth
        addCursorRect(NSRect(x: 0, y: edge, width: edge, height: bounds.height - edge * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - edge, y: edge, width: edge, height: bounds.height - edge * 2), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: edge, y: 0, width: bounds.width - edge * 2, height: edge), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: edge, y: bounds.height - edge, width: bounds.width - edge * 2, height: edge), cursor: .resizeUpDown)
        for x in [CGFloat(0), bounds.width - edge] {
            for y in [CGFloat(0), bounds.height - edge] {
                addCursorRect(NSRect(x: x, y: y, width: edge, height: edge), cursor: .crosshair)
            }
        }
        addCursorRect(NSRect(x: edge, y: bounds.height - WindowInteractionRegions.dragHeight,
            width: bounds.width - edge * 2, height: WindowInteractionRegions.dragHeight - edge), cursor: .openHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}

struct WindowInteractionAreas: NSViewRepresentable {
    let backgroundOpacity: Double
    func makeNSView(context: Context) -> WindowInteractionView {
        let view = WindowInteractionView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WindowInteractionView, context: Context) {
        view.backgroundOpacity = backgroundOpacity
    }
}

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = Self(rawValue: 1)
    static let right = Self(rawValue: 2)
    static let bottom = Self(rawValue: 4)
    static let top = Self(rawValue: 8)

    static func hitTest(_ point: NSPoint, size: NSSize) -> Self {
        var result: Self = []
        guard NSRect(origin: .zero, size: size).contains(point) else { return [] }
        let edge = WindowInteractionRegions.edgeWidth
        if point.x <= edge { result.insert(.left) }
        else if point.x >= size.width - edge { result.insert(.right) }
        if point.y <= edge { result.insert(.bottom) }
        else if point.y >= size.height - edge { result.insert(.top) }
        return result
    }

    func resizedFrame(from frame: NSRect, delta: NSPoint, minimum: NSSize) -> NSRect {
        var result = frame
        if contains(.left) {
            result.size.width = max(minimum.width, frame.width - delta.x)
            result.origin.x = frame.maxX - result.width
        } else if contains(.right) { result.size.width = max(minimum.width, frame.width + delta.x) }
        if contains(.bottom) {
            result.size.height = max(minimum.height, frame.height - delta.y)
            result.origin.y = frame.maxY - result.height
        } else if contains(.top) { result.size.height = max(minimum.height, frame.height + delta.y) }
        return result
    }
}

enum PanelWindowGeometry {
    static func expandedFrame(from frame: NSRect, within visible: NSRect) -> NSRect {
        let size = NSSize(width: min(visible.width, max(frame.width, 560)),
                          height: min(visible.height, max(frame.height, 580)))
        let x = min(max(visible.minX, frame.midX - size.width / 2), max(visible.minX, visible.maxX - size.width))
        let y = min(max(visible.minY, frame.midY - size.height / 2), max(visible.minY, visible.maxY - size.height))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// Borderless windows need explicit key/main eligibility and edge resizing.
final class ReaderWindow: NSWindow {
    static let minimumReadingSize = NSSize(width: 240, height: 160)
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override var minSize: NSSize {
        get {
            NSSize(width: max(super.minSize.width, Self.minimumReadingSize.width),
                   height: max(super.minSize.height, Self.minimumReadingSize.height))
        }
        set {
            super.minSize = NSSize(width: max(newValue.width, Self.minimumReadingSize.width),
                                   height: max(newValue.height, Self.minimumReadingSize.height))
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if !styleMask.contains(.fullScreen) {
            frame.size.width = max(frame.width, Self.minimumReadingSize.width)
            frame.size.height = max(frame.height, Self.minimumReadingSize.height)
        }
        super.setFrame(frame, display: flag)
    }

    func trackMove(from event: NSEvent) {
        let original = frame.origin
        let start = convertPoint(toScreen: event.locationInWindow)
        while let drag = nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                  until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let point = convertPoint(toScreen: drag.locationInWindow)
            setFrameOrigin(NSPoint(x: original.x + point.x - start.x, y: original.y + point.y - start.y))
            if drag.type == .leftMouseUp { break }
        }
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !styleMask.contains(.fullScreen), attachedSheet == nil {
            if event.modifierFlags.contains(.option) {
                trackMove(from: event)
                return
            }
            let edges = ResizeEdges.hitTest(event.locationInWindow, size: frame.size)
            if !edges.isEmpty {
                trackResize(from: event, edges: edges)
                return
            }
        }
        super.sendEvent(event)
    }

    func trackResize(from event: NSEvent, edges: ResizeEdges) {
        let original = frame
        let start = convertPoint(toScreen: event.locationInWindow)
        // Keep receiving the drag after the pointer leaves the original window bounds.
        while let drag = nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                   until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            let point = convertPoint(toScreen: drag.locationInWindow)
            let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
            setFrame(edges.resizedFrame(from: original, delta: delta, minimum: minSize), display: true)
            if drag.type == .leftMouseUp { break }
        }
    }
}
