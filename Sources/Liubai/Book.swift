import Foundation
import CoreFoundation

struct Chapter: Identifiable, Codable, Equatable {
    let id: Int
    let title: String
    let location: Int
    let length: Int
    let isHeading: Bool
}

struct Book: Codable, Equatable {
    var title: String
    var text: String
    var chapters: [Chapter]
    var position: Int = 0
    var progress: Double = 0

    init(title: String, text: String) {
        self.title = title
        self.text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        self.chapters = Self.findChapters(in: self.text)
    }

    static func findChapters(in text: String) -> [Chapter] {
        let pattern = #"^\s*(?:第[零〇一二三四五六七八九十百千万两0-9]+[章节回卷部篇集](?:\s|[：:、.．—-]|[^\x00-\x7F]|$).*|(?:chapter|part|book)\s+[0-9IVXLCDM]+\b.*|(?:序章|序言|前言|楔子|引子|尾声|终章|后记|番外)(?:\s.*|[：:、].*|$))$"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let source = text as NSString
        var chapters: [Chapter] = []
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let title = line.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty && title.count <= 80,
               regex.firstMatch(in: line, range: NSRange(location: 0, length: length)) != nil {
                chapters.append(Chapter(id: chapters.count, title: title,
                                        location: offset, length: length, isHeading: true))
            }
            offset += length + 1
        }
        if chapters.isEmpty {
            return [Chapter(id: 0, title: "正文", location: 0, length: 0, isHeading: false)]
        }
        if chapters[0].location > 0 {
            let prefix = source.substring(to: chapters[0].location)
            if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters.insert(Chapter(id: -1, title: "开篇", location: 0,
                                        length: 0, isHeading: false), at: 0)
            }
        }
        return chapters
    }

    func chapterIndex(at position: Int) -> Int {
        chapters.lastIndex(where: { $0.location <= position }) ?? 0
    }

    static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0, 0]), let s = String(data: data, encoding: .utf32LittleEndian) { return s }
        if bytes.starts(with: [0, 0, 0xFE, 0xFF]), let s = String(data: data, encoding: .utf32BigEndian) { return s }
        if bytes.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if bytes.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: big5)) { return s }
        throw ReaderError.encoding
    }

    static let sample = Book(title: "山间来信", text: """
    山间来信

    第一章 一条安静的路

    入秋以后，山里的早晨比城里来得慢一些。

    阳光还没有照到屋檐，薄雾先沿着河流走来。院子里落了一夜的桂花，细小的，浅黄色的，没有声音。推开窗，凉意和花香一起进来。我把昨天读到一半的书放在桌上，烧了一壶水。

    搬来这里之前，我总觉得一天太短。消息要回，事情要做，连散步也要记着步数。后来我发现，山里的时间并没有更多，只是没有人催它。

    屋后有一条小路，沿着竹林往上走，会经过一座石桥。桥很窄，刚够两个人错身。桥下的水很清，能看见石头上缓慢摇动的水草。

    我通常在早饭之后出门，不带什么，也不规定走到哪里。遇见一棵好看的树，就站一会儿。听见远处的鸟声，就停下来听。有时候走了很久，有时候只走到桥边。

    今天在桥上遇见一位老人。他提着竹篮，里面是刚摘的柿子。他问我住在哪里，我指了指竹林后面的屋顶。他点头说，那边下午的太阳很好。

    我们没有再说别的。水从桥下流过，带走一片叶子。我忽然想到，原来有些交谈，只需要这么短。

    回家时，阳光刚好照在桌沿上。书还在那里，水已经不烫了。我坐下来，接着昨天那一页往下读。

    第二章 雨在窗外

    雨是从下午开始下的。起初只有几滴，落在门前的石板上，留下深色的小圆点。过了一会儿，小圆点连在一起，整条路都湿了。

    我把窗户关上一半。剩下的一半，刚好能听见雨，又不会打湿桌上的纸。

    对面山上的树变得模糊，屋檐滴水的声音却很清楚。这样的下午适合读一封长信，或者写一封不用着急寄出的信。想不出写给谁，便先写日期。

    信纸上只有一句话：今天下雨了。

    写完以后，觉得这句话已经够了。它没有解释我的生活，却把此刻好好地留了下来。

    我开始翻那本旧书。书页边角微微发黄，有几处折痕，不知道是谁留下的。翻到某一页，夹着一片很薄的银杏叶。叶脉细得像一张地图，而地图的尽头是一段谁也不知道的秋天。

    傍晚雨停了，空气湿润而清凉。我出门把院子里的凳子擦干，坐着看天。云缝里露出一点蓝，晚风从山谷吹过来。远处有人叫孩子回家吃饭，声音在山间停了一会儿，才慢慢消失。

    第三章 一盏灯的距离

    山里天黑得很彻底。最后一抹光退到树梢以后，窗外就只剩下深浅不同的影子。

    我打开桌上的灯。灯罩很旧，光却柔和，照亮书，也照亮杯子旁边那一小块桌面。白天看不见的木纹，在这样的光里清晰起来。

    有一次停电，我点了一根蜡烛。火苗被门缝里的风吹得轻轻偏向一边。我担心它熄灭，就把门关好，坐回来。那晚读得比平时慢，字像一颗颗小石头，需要逐个拾起来。

    可我记住了那晚读过的每一句话。

    后来电来了，我没有立刻开灯。蜡烛还剩下一半，书也还没有读完。窗外的虫鸣断断续续，像有人在远处试着拨一把很小的琴。

    读到最后一页时，我把书合上。屋子里没有什么必须马上完成的事。水壶静静站在灶台上，外套挂在门后，明天的路在黑暗里等着。

    我想，所谓安静，也许就是允许这一刻只有这一刻。

    第四章 给远方的朋友

    你在信里问，住在山里会不会无聊。

    我想了几天，不知道怎么回答。这里确实没有多少事情发生。但春天竹笋会长出来，夏天有很长的蝉鸣，秋天能看见鸟群经过，冬天的屋檐上偶尔落雪。

    这些事情年年都有，每次却都不太一样。

    今天我去镇上买东西。在回来的路上，遇到一只小狗跟了我很远。走到石桥边，它停下来，似乎觉得自己的职责已经完成，转身跑回去了。

    我在篮子里放了茶、面包和两支铅笔。铅笔是给你的。店主说这批铅笔的木头很好，削的时候会有香味。我不知道是不是，但总觉得你会喜欢。

    如果你来，床已经铺好了。你不用准备特别的行李，也不用提前想好要做什么。我们可以早起，也可以睡到太阳照进来。可以走到很远的地方，也可以一整天坐在窗边。

    书架上有你上次提过的那本书。我一直没有读，想等你来，听你讲讲为什么喜欢它。

    写到这里，天又快黑了。我把灯打开，窗玻璃上映出一个很小的房间。房间里有桌子，有书，有一封快要写完的信。

    山里的日子大概就是这样。等你来，我们慢慢说。
    """)
}

enum ReaderError: LocalizedError {
    case encoding, empty, tooLarge
    var errorDescription: String? {
        switch self {
        case .encoding: return "无法识别文字编码，请将文件保存为 UTF-8 后重新打开。"
        case .empty: return "这个文件还没有文字，请选择另一个 TXT 文件。"
        case .tooLarge: return "文件超过 30 MB，请分成几个较小的 TXT 文件后打开。"
        }
    }
}

struct SearchResult: Identifiable, Equatable {
    let id: Int
    let range: NSRange
    let chapter: String
    let before: String
    let match: String
    let after: String
}

struct SearchResponse {
    let results: [SearchResult]
    let total: Int
}

enum BookSearch {
    static func find(_ query: String, in book: Book, limit: Int = 300) -> SearchResponse {
        guard !query.isEmpty else { return SearchResponse(results: [], total: 0) }
        let text = book.text as NSString
        var results: [SearchResult] = []
        var start = 0
        var total = 0
        while start < text.length {
            let range = text.range(of: query, options: [.caseInsensitive],
                                   range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound else { break }
            total += 1
            if results.count < limit {
                let left = max(0, range.location - 24)
                let right = min(text.length, NSMaxRange(range) + 42)
                let snippetRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: left, length: right - left))
                let before = text.substring(with: NSRange(location: snippetRange.location, length: range.location - snippetRange.location))
                let after = text.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(snippetRange) - NSMaxRange(range)))
                results.append(SearchResult(id: results.count, range: range,
                    chapter: book.chapters[book.chapterIndex(at: range.location)].title,
                    before: before.replacingOccurrences(of: "\n", with: " "),
                    match: text.substring(with: range), after: after.replacingOccurrences(of: "\n", with: " ")))
            }
            start = NSMaxRange(range)
            if Task.isCancelled { break }
        }
        return SearchResponse(results: results, total: total)
    }
}
