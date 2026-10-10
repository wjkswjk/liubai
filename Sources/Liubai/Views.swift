import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let ink = Color(NSColor(hex: "33373F"))
private let muted = Color(NSColor(hex: "92969E"))
private let accent = Color(NSColor(hex: "706687"))
private let canvas = Color(NSColor(hex: "F7F8FA"))

struct QuietButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(primary ? .white : ink)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(primary ? ink : Color.black.opacity(configuration.isPressed ? 0.07 : 0.035))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct RootView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if model.book != nil {
                    ReaderView(model: model)
                        .background(Color(model.preferences.readingBackground))
                        .ignoresSafeArea()
                } else {
                    WelcomeView(model: model)
                }
                if let tab = model.panel {
                    Color.black.opacity(0.16).ignoresSafeArea()
                        .onTapGesture { model.panel = nil }
                        .accessibilityLabel("关闭面板")
                    ControlPanel(model: model, tab: tab)
                        .frame(width: min(620, geometry.size.width - 32), height: min(630, geometry.size.height - 40))
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                if model.dragOver {
                    canvas.opacity(0.95).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 32, weight: .ultraLight))
                        Text("松开，开始阅读").font(.system(size: 20))
                    }.foregroundColor(ink)
                }
                if model.isLoading {
                    canvas.opacity(0.92).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.small)
                        Text("正在打开文字…").font(.system(size: 13)).foregroundColor(muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(WindowInteractionAreas(backgroundOpacity: model.book == nil ? 1 : model.preferences.backgroundOpacity))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.dragOver) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.load(url) }
                }
                return true
            }
        }
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        .alert("暂时无法打开", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: model.bookID) { _ in updateWindow() }
        .onChange(of: model.panel) { _ in updateWindow() }
        .onAppear { updateWindow() }
    }

    private func updateWindow() {
        let reading = model.book != nil && model.panel == nil
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            model.window?.standardWindowButton(kind)?.isHidden = reading
        }
        model.window?.isMovableByWindowBackground = model.book == nil
    }
}

struct WelcomeView: View {
    @ObservedObject var model: ReaderModel
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 32)
                    Image(systemName: "book.closed")
                        .font(.system(size: 30, weight: .ultraLight)).foregroundColor(accent)
                        .frame(width: 70, height: 70)
                        .background(Color(NSColor(hex: "EEECF2")))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Text("留白").font(.custom("Songti SC", size: 46)).tracking(12)
                        .padding(.leading, 12).padding(.top, 24).foregroundColor(ink)
                    Text("一个安静的 TXT 阅读器").font(.system(size: 13)).tracking(2)
                        .foregroundColor(muted).padding(.top, 10)

                    VStack(spacing: 18) {
                        Button { model.openFile() } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                                Text("打开 TXT 文件")
                                Text("⌘ O").foregroundColor(.white.opacity(0.45)).padding(.leading, 18)
                            }
                        }.buttonStyle(QuietButtonStyle(primary: true))
                        Text("也可以把文件拖到这里").font(.system(size: 12)).foregroundColor(muted)
                    }.padding(.top, 38)

                    Button { model.present(Book.sample) } label: {
                        HStack(spacing: 6) {
                            Text("先读一段文字")
                            Image(systemName: "arrow.right").font(.system(size: 10))
                        }.font(.system(size: 12)).foregroundColor(accent)
                    }.buttonStyle(.plain).padding(.top, 30)

                    Spacer(minLength: 42)
                    VStack(spacing: 8) {
                        Text("阅读时，右键点击正文或按退出键打开面板")
                        Text("自由调整窗口 · 自动换行 · 阅读记录保存在本机")
                    }.font(.system(size: 11)).foregroundColor(muted)
                        .multilineTextAlignment(.center).padding(.bottom, 28)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }.scrollIndicators(.hidden).background(canvas)
        }.ignoresSafeArea()
    }
}

struct ControlPanel: View {
    @ObservedObject var model: ReaderModel
    var tab: PanelTab
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.book?.title ?? "留白").font(.system(size: 17, weight: .medium))
                        .lineLimit(1).foregroundColor(ink)
                    if let book = model.book {
                        Text("\(book.chapters[book.chapterIndex(at: model.currentPosition)].title)  ·  \(Int(model.progress * 100))%")
                            .font(.system(size: 11)).foregroundColor(muted).lineLimit(1)
                    } else {
                        Text("让文字按你的习惯呈现").font(.system(size: 11)).foregroundColor(muted)
                    }
                }
                Spacer()
                Button { model.panel = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .foregroundColor(muted).frame(width: 28, height: 28)
                        .background(canvas).clipShape(Circle())
                }.buttonStyle(.plain).help("回到阅读（退出键）").accessibilityLabel("关闭面板")
            }.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 21)

            HStack(spacing: 4) {
                ForEach(PanelTab.allCases) { item in
                    Button { model.panel = item } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon).font(.system(size: 12))
                            Text(item.rawValue).font(.system(size: 13, weight: tab == item ? .medium : .regular))
                        }.foregroundColor(tab == item ? accent : muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(tab == item ? Color(NSColor(hex: "EEECF2")) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).disabled(model.book == nil && (item == .chapters || item == .search || item == .listening))
                }
            }.padding(4).background(canvas).clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 26).padding(.bottom, 18)

            Group {
                switch tab {
                case .chapters: ChapterList(model: model)
                case .search: SearchPanel(model: model)
                case .listening: ListeningPanel(model: model, listening: model.listening)
                case .appearance: AppearancePanel(model: model)
                case .shortcuts: ShortcutPanel(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
            HStack {
                Button { model.openFile() } label: {
                    Label("打开另一本", systemImage: "folder").font(.system(size: 11)).foregroundColor(muted)
                }.buttonStyle(.plain).help("打开 TXT（⌘O）")
                Spacer()
                Button { model.panel = nil } label: {
                    HStack(spacing: 8) { Text("继续阅读"); Text("退出键").foregroundColor(muted) }
                        .font(.system(size: 11)).foregroundColor(ink)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 26).padding(.vertical, 17)
        }
    }
}

struct ListeningPanel: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var listening: ListeningController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把这一页，读给你听").font(.system(size: 15, weight: .medium)).foregroundColor(ink)
                    HStack(spacing: 8) {
                        if listening.state == .loading { ProgressView().controlSize(.small) }
                        Text(listening.status).font(.system(size: 12)).foregroundColor(listening.state == .failed ? accent : muted)
                    }
                }
                HStack(spacing: 10) {
                    if listening.isActive {
                        Button(listening.state == .paused ? "继续听" : "暂停") { listening.togglePause() }
                            .buttonStyle(QuietButtonStyle(primary: true))
                        Button("停止") { listening.stop() }.buttonStyle(QuietButtonStyle())
                    } else {
                        Button("从当前页开始") {
                            model.flushPosition()
                            listening.start(at: model.currentPosition)
                        }.buttonStyle(QuietButtonStyle(primary: true)).disabled(model.book == nil)
                        if listening.canResume {
                            Button("继续上次听书") { listening.resumeBookmark() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                if listening.isActive, let chunk = listening.currentChunk {
                    Text(chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12)).foregroundColor(ink).lineSpacing(6).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(canvas).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("音色").font(.system(size: 11, weight: .medium)).foregroundColor(ink)
                    Picker("音色", selection: $listening.voice) {
                        ForEach(ListeningVoice.all) { voice in Text(voice.name).tag(voice.id) }
                    }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel("听书音色")
                    Text("切换音色后，从这段文字重新开始。")
                        .font(.system(size: 10)).foregroundColor(muted)
                }
                VStack(spacing: 9) {
                    HStack {
                        Text("播放速度").font(.system(size: 11, weight: .medium)).foregroundColor(ink)
                        Spacer()
                        Text(String(format: "%.2g 倍", listening.speed)).font(.system(size: 11, design: .monospaced)).foregroundColor(muted)
                    }
                    Slider(value: $listening.speed, in: 0.75...2, step: 0.25)
                        .tint(accent).controlSize(.small).accessibilityLabel("听书播放速度")
                }
                Toggle("跟随朗读翻页", isOn: $listening.followsText).font(.system(size: 12)).foregroundColor(ink)
                Text("语音按段生成，自动接着往下读。生成时需要联网，待朗读文字会发送给微软；缓存的音频可重复播放，进度自动保存在本机。")
                    .font(.system(size: 11)).foregroundColor(muted).lineSpacing(5)
            }.padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 24)
        }
    }
}

struct ChapterList: View {
    @ObservedObject var model: ReaderModel
    var body: some View {
        if let book = model.book {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                            let active = book.chapterIndex(at: model.currentPosition) == index
                            Button { model.navigate(NSRange(location: chapter.location, length: 0)) } label: {
                                HStack(spacing: 14) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 11, design: .monospaced)).foregroundColor(active ? accent : muted)
                                    Text(chapter.title).font(.system(size: 13)).foregroundColor(active ? accent : ink)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    if active { Circle().fill(accent).frame(width: 5, height: 5) }
                                }.padding(.horizontal, 14).padding(.vertical, 14)
                                    .background(active ? Color(NSColor(hex: "F2F0F5")) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(chapter.id)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 16)
                }
                .onAppear { proxy.scrollTo(book.chapters[book.chapterIndex(at: model.currentPosition)].id, anchor: .center) }
            }
        }
    }
}

struct SearchPanel: View {
    @ObservedObject var model: ReaderModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundColor(muted)
                TextField("搜索这本书里的文字", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                    .onSubmit { if let result = model.searchResults.first { model.navigate(result.range, highlight: true) } }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(muted)
                    }.buttonStyle(.plain).accessibilityLabel("清空搜索")
                }
            }.padding(13).background(canvas).clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 26)
            if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 29, weight: .ultraLight))
                    Text("找一个词，回到那段文字").font(.system(size: 12))
                }.foregroundColor(muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isSearching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.searchResults.isEmpty {
                Text("没有找到「\(model.query)」").font(.system(size: 12)).foregroundColor(muted)
                    .padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text(model.searchTotal > 300 ? "找到 \(model.searchTotal) 处，显示前 300 处" : "找到 \(model.searchTotal) 处")
                    Spacer()
                    Text("点击跳转")
                }.font(.system(size: 10)).foregroundColor(muted)
                    .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.searchResults) { result in
                            Button { model.navigate(result.range, highlight: true) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(result.chapter).font(.system(size: 10)).foregroundColor(muted)
                                    (Text(result.before).foregroundColor(ink) +
                                     Text(result.match).foregroundColor(accent).bold() +
                                     Text(result.after).foregroundColor(ink))
                                        .font(.system(size: 12)).lineSpacing(5).lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 28).padding(.vertical, 14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Rectangle().fill(Color.black.opacity(0.04)).frame(height: 1).padding(.horizontal, 28)
                        }
                    }.padding(.bottom, 10)
                }
            }
        }.padding(.bottom, 12).onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

struct AppearancePanel: View {
    @ObservedObject var model: ReaderModel
    private let fonts = [("宋体", "Songti SC"), ("黑体", "PingFang SC"), ("楷体", "Kaiti SC"), ("系统", ".AppleSystemUIFont")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 13) {
                    caption("纸张")
                    HStack(spacing: 10) {
                        ForEach(ReaderPreferences.themes, id: \.name) { theme in
                            Button {
                                model.preferences.background = theme.background
                                model.preferences.foreground = theme.foreground
                            } label: {
                                VStack(spacing: 7) {
                                    Text("字").font(.custom("Songti SC", size: 20))
                                        .foregroundColor(Color(NSColor(hex: theme.foreground)))
                                        .frame(maxWidth: .infinity).frame(height: 44)
                                        .background(Color(NSColor(hex: theme.background)))
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7)
                                            .stroke(model.preferences.background == theme.background ? accent : Color.black.opacity(0.09),
                                                    lineWidth: model.preferences.background == theme.background ? 1.5 : 1))
                                    Text(theme.name).font(.system(size: 10)).foregroundColor(muted)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("\(theme.name)主题")
                        }
                    }
                    HStack(spacing: 22) {
                        ColorPicker("背景颜色", selection: colorBinding(\.background), supportsOpacity: false)
                        ColorPicker("文字颜色", selection: colorBinding(\.foreground), supportsOpacity: false)
                    }.font(.system(size: 11)).foregroundColor(muted)
                }
                VStack(alignment: .leading, spacing: 9) {
                    settingsSlider("背景透明度", value: Binding(
                        get: { (1 - model.preferences.backgroundOpacity) * 100 },
                        set: { model.preferences.backgroundOpacity = 1 - $0 / 100 }
                    ), range: 0...100, suffix: "%")
                    HStack {
                        Text("不透明")
                        Spacer()
                        Text("完全透明")
                    }.font(.system(size: 10)).foregroundColor(muted)
                    Text("只调整背景，文字保持清晰。透明时仍可拖动窗口边缘缩放。")
                        .font(.system(size: 10)).foregroundColor(muted).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 11) {
                    caption("字体")
                    HStack(spacing: 7) {
                        ForEach(fonts, id: \.1) { name, value in
                            Button { model.preferences.fontName = value } label: {
                                Text(name).font(.system(size: 12))
                                    .foregroundColor(model.preferences.fontName == value ? accent : muted)
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(model.preferences.fontName == value ? Color(NSColor(hex: "EEECF2")) : canvas)
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                settingsSlider("字号", value: $model.preferences.fontSize, range: 12...48, suffix: "磅")
                settingsSlider("行间距", value: $model.preferences.lineSpacing, range: 2...30, suffix: "磅")
                settingsSlider("页边距", value: $model.preferences.margin, range: 16...160, suffix: "磅")

                VStack(alignment: .leading, spacing: 10) {
                    caption("预览")
                    Text("让阅读慢下来，让文字留下来。")
                        .font(Font(model.preferences.nsFont)).foregroundColor(Color(NSColor(hex: model.preferences.foreground)))
                        .lineSpacing(model.preferences.lineSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        .background(Color(model.preferences.readingBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack(alignment: .top) {
                    Text("设置自动保存，窗口缩放时文字自动换行。")
                        .font(.system(size: 10)).foregroundColor(muted)
                    Spacer()
                    Button("恢复默认") { model.preferences = ReaderPreferences() }
                        .font(.system(size: 10)).foregroundColor(accent).buttonStyle(.plain)
                }
            }.padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 4)
        }
    }

    private func caption(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(ink)
    }

    private func settingsSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 9) {
            HStack {
                caption(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)").font(.system(size: 11, design: .monospaced)).foregroundColor(muted)
            }
            Slider(value: value, in: range, step: 1).tint(accent).controlSize(.small).accessibilityLabel(title)
        }
    }

    private func colorBinding(_ key: WritableKeyPath<ReaderPreferences, String>) -> Binding<Color> {
        Binding(get: { Color(NSColor(hex: model.preferences[keyPath: key])) },
                set: { model.preferences[keyPath: key] = NSColor($0).hex })
    }
}

struct ShortcutPanel: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("按你的习惯翻页").font(.system(size: 15, weight: .medium)).foregroundColor(ink)
                    Text("点击下方按键，然后按下想使用的单键或组合键。")
                        .font(.system(size: 12)).foregroundColor(muted).lineSpacing(5)
                }
                ForEach(PageDirection.allCases) { direction in
                    HStack(spacing: 12) {
                        Text(direction.rawValue).font(.system(size: 13)).foregroundColor(ink)
                        Spacer(minLength: 8)
                        Button {
                            model.shortcutMessage = nil
                            model.recordingShortcut = direction
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.recordingShortcut == direction ? "record.circle" : "keyboard")
                                    .font(.system(size: 12))
                                Text(model.recordingShortcut == direction ? "请按下快捷键…" : model.pagingShortcuts[direction].display)
                                    .font(.system(size: 12, weight: .medium))
                            }.foregroundColor(accent).padding(.horizontal, 14).padding(.vertical, 11)
                                .background(Color(NSColor(hex: "EEECF2")))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).accessibilityLabel("设置\(direction.rawValue)快捷键")
                    }
                }
                if let message = model.shortcutMessage {
                    Text(message).font(.system(size: 11)).foregroundColor(accent).lineSpacing(4)
                } else if model.recordingShortcut != nil {
                    Text("按退出键取消录入。")
                        .font(.system(size: 11)).foregroundColor(accent)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("翻页时会保留一行重叠文字，方便接着阅读。")
                    Text("快捷键仅在阅读时生效，不影响搜索和输入。")
                    Text("退出键和应用已有的快捷键不能用于翻页。")
                }.font(.system(size: 11)).foregroundColor(muted).lineSpacing(4)
                Button("恢复默认翻页键") {
                    model.pagingShortcuts = PagingShortcuts()
                    model.recordingShortcut = nil
                    model.shortcutMessage = "已恢复默认翻页键。"
                }.font(.system(size: 11)).foregroundColor(accent).buttonStyle(.plain)
                Text("快捷键自动保存，重新打开应用仍然有效。")
                    .font(.system(size: 10)).foregroundColor(muted)
            }.padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 24)
        }
    }
}
