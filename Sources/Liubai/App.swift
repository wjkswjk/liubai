import AppKit
import SwiftUI

@main
@MainActor
struct LiubaiMain {
    static func main() {
        // App-scoped language preference; the Mac's system language stays unchanged.
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = ReaderModel()
    var window: NSWindow!
    var pendingURL: URL?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        window = ReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
                          styleMask: [.borderless, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "留白"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.minSize = ReaderWindow.minimumReadingSize
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrameAutosaveName("LiubaiReaderWindow")
        if UserDefaults.standard.string(forKey: "NSWindow Frame LiubaiReaderWindow") == nil { window.center() }
        model.window = window
        let hosting = TransparentHostingView(rootView: RootView(model: model))
        // SwiftUI's ideal size must not override the freely resizable window.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.minSize = ReaderWindow.minimumReadingSize
        var restored = window.frame
        restored.size.width = max(restored.width, window.minSize.width)
        restored.size.height = max(restored.height, window.minSize.height)
        window.setFrame(restored, display: false)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window, self.window.attachedSheet == nil else { return event }
            if self.model.recordingShortcut != nil {
                self.model.recordShortcut(event)
                return nil
            }
            if event.keyCode == 53, self.model.panel != nil {
                self.model.panel = nil
                return nil
            }
            if self.model.panel == nil, self.model.book != nil, !self.model.isLoading,
               let direction = self.model.pagingShortcuts.direction(for: event) {
                self.model.page(direction)
                return nil
            }
            return event
        }
        if let pendingURL { model.load(pendingURL) }
        else { model.restore() }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let file = filenames.first else { return }
        let url = URL(fileURLWithPath: file)
        if window != nil { model.load(url) } else { pendingURL = url }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func makeMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "留白")
        add(appMenu, "关于留白", #selector(about), "")
        appMenu.addItem(.separator())
        add(appMenu, "外观设置…", #selector(appearance), ",")
        add(appMenu, "翻页快捷键…", #selector(shortcuts), ",", modifiers: [.command, .shift])
        appMenu.addItem(.separator())
        add(appMenu, "隐藏留白", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(appMenu, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", target: NSApp, modifiers: [.command, .option])
        add(appMenu, "显示全部", #selector(NSApplication.unhideAllApplications(_:)), "", target: NSApp)
        appMenu.addItem(.separator())
        add(appMenu, "退出留白", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        submenu(main, appMenu)

        let file = NSMenu(title: "文件")
        add(file, "打开 TXT…", #selector(openFile), "o")
        add(file, "阅读示例", #selector(sample), "")
        file.addItem(.separator())
        add(file, "关闭窗口", #selector(closeWindow), "w")
        submenu(main, file)

        let edit = NSMenu(title: "编辑")
        add(edit, "撤销", Selector(("undo:")), "z", target: nil)
        add(edit, "重做", Selector(("redo:")), "z", target: nil, modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), "x", target: nil)
        add(edit, "复制", #selector(NSText.copy(_:)), "c", target: nil)
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v", target: nil)
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a", target: nil)
        submenu(main, edit)

        let reading = NSMenu(title: "阅读")
        add(reading, "章节目录", #selector(chapters), "t")
        add(reading, "搜索文字…", #selector(search), "f")
        reading.addItem(.separator())
        add(reading, "上一页", #selector(previousPage), "")
        add(reading, "下一页", #selector(nextPage), "")
        add(reading, "自定义翻页快捷键…", #selector(shortcuts), "")
        reading.addItem(.separator())
        add(reading, "上一章", #selector(previous), "\u{F702}", modifiers: [.command, .option])
        add(reading, "下一章", #selector(next), "\u{F703}", modifiers: [.command, .option])
        reading.addItem(.separator())
        add(reading, "放大文字", #selector(increaseFont), "=")
        add(reading, "缩小文字", #selector(decreaseFont), "-")
        submenu(main, reading)

        let windows = NSMenu(title: "窗口")
        add(windows, "最小化", #selector(minimize), "m")
        add(windows, "进入 / 退出全屏", #selector(fullscreen), "f", modifiers: [.command, .control])
        submenu(main, windows)
        NSApp.windowsMenu = windows

        let help = NSMenu(title: "帮助")
        add(help, "使用说明", #selector(helpPanel), "?")
        submenu(main, help)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    private func submenu(_ parent: NSMenu, _ child: NSMenu) {
        let item = NSMenuItem(title: child.title, action: nil, keyEquivalent: "")
        item.submenu = child
        parent.addItem(item)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                     target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // Editing actions intentionally use the responder chain.
        item.target = target ?? (["cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:"].contains(NSStringFromSelector(action)) ? nil : self)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }

    @objc func openFile() { model.openFile() }
    @objc func sample() { model.present(Book.sample) }
    @objc func appearance() { model.togglePanel(.appearance) }
    @objc func chapters() { if model.book != nil { model.togglePanel(.chapters) } }
    @objc func search() { if model.book != nil { model.togglePanel(.search) } }
    @objc func shortcuts() { model.togglePanel(.shortcuts) }
    @objc func previousPage() { model.page(.previous) }
    @objc func nextPage() { model.page(.next) }
    @objc func previous() { model.adjacentChapter(-1) }
    @objc func next() { model.adjacentChapter(1) }
    @objc func increaseFont() { model.preferences.fontSize = min(48, model.preferences.fontSize + 1) }
    @objc func decreaseFont() { model.preferences.fontSize = max(12, model.preferences.fontSize - 1) }
    @objc func closeWindow() { window.performClose(nil) }
    @objc func minimize() { window.miniaturize(nil) }
    @objc func fullscreen() { window.toggleFullScreen(nil) }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "留白", .applicationVersion: "1.3.0",
            .credits: NSAttributedString(string: "一个安静的 TXT 阅读器\n原生 macOS · 离线阅读 · 自动保存"),
            .version: ""
        ])
    }
    @objc func helpPanel() {
        let alert = NSAlert()
        alert.messageText = "只留下文字"
        alert.informativeText = "右键点击正文或按退出键，打开 / 关闭面板。\n拖动窗口边缘可任意调整大小，文字自动换行。\n拖动正文空白可移动窗口。翻页立即切换，无滚动动画。窗口没有边框和阴影。\n\n上一页键 / 下一页键  翻页（可自定义）\n⌘ ⇧ ,  自定义翻页快捷键\n⌘ O  打开 TXT 文件\n⌘ T  章节目录\n⌘ F  搜索文字\n⌘ ,  外观设置\n⌘ + / −  调整字号\n⌘ ⌥ ← / →  上一章 / 下一章\n⌃ ⌘ F  全屏\n⌘ W  关闭窗口\n⌘ Q  退出\n\n阅读进度、外观及快捷键自动保存在本机，重新打开即可继续。"
        alert.addButton(withTitle: "开始阅读")
        alert.beginSheetModal(for: window)
    }
}
