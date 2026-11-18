import AppKit
import ImageIO
#if canImport(Shared)
import Shared
#endif

/// 「雨雲の動き」のサブメニュー。親の項目に現在地の雨の様子を添え、開くと地図のカードを
/// 出す。地図は気象庁の高解像度降水ナウキャストのタイルを、国土地理院の地図に重ねたもの。
struct RadarCard {
    /// サブメニューの親の項目
    let itemLine: String
    /// サブメニューの中身 (先頭の「--」まで付けた行)
    let submenuLines: [String]

    var lines: [String] { [itemLine] + submenuLines }
}

/// 降水の強さの段階。気象庁の高解像度降水ナウキャストのタイルの配色で、タイルの画素の
/// 色はこのどれかと一致する (2026-11-18 に山陰の雨域のタイルで確かめた)
enum RainLevel {
    static let colors: [UInt32] = [0xF2F2FF, 0xA0D2FF, 0x218CFF, 0x0041FF, 0xFAF500, 0xFF9900, 0xFF2800, 0xB40068]
    /// 段階の境目 (mm/h)
    static let bounds = [1, 5, 10, 20, 30, 50, 80]

    /// 画素の色の段階。透明なら nil。配色と一致しない色は、いちばん近い色の段階にする
    static func level(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Int? {
        guard alpha > 0 else { return nil }
        let distances = colors.map { color -> Int in
            let dr = Int(red) - Int((color >> 16) & 0xff)
            let dg = Int(green) - Int((color >> 8) & 0xff)
            let db = Int(blue) - Int(color & 0xff)
            return dr * dr + dg * dg + db * db
        }
        return distances.indices.min { distances[$0] < distances[$1] }
    }

    /// 段階の強さの幅
    static func range(_ level: Int) -> String {
        switch level {
        case 0: L("1 mm/h 未満", "under 1 mm/h")
        case bounds.count...: L("\(bounds[bounds.count - 1]) mm/h 以上", "\(bounds[bounds.count - 1])+ mm/h")
        default: L("\(bounds[level - 1])〜\(bounds[level]) mm/h", "\(bounds[level - 1])–\(bounds[level]) mm/h")
        }
    }
}

/// 地図に出す範囲。地点を中心に、ズーム 8 のタイルの画素で 680×440 を切り出す。
/// カードには 1 画素を 0.5pt (2 倍の画素で描く PNG の 1 画素) で描くので、地図は
/// 340×220pt になり、タイルを拡大も縮小もせずに描ける。ズーム 8 の 1 画素はおよそ
/// 500m なので、地図の幅は東京から見て横浜〜宇都宮くらいの範囲 (約 300km) になる。
struct RadarView {
    static let zoom = 8
    static let pixelWidth: Double = 680
    static let pixelHeight: Double = 440

    /// 地点の、ズーム 8 の全体の画素での位置
    let centerX: Double
    let centerY: Double

    init(latitude: Double, longitude: Double) {
        let worldSize = 256 * pow(2, Double(Self.zoom))
        let phi = latitude * .pi / 180
        centerX = (longitude + 180) / 360 * worldSize
        centerY = (1 - log(tan(phi) + 1 / cos(phi)) / .pi) / 2 * worldSize
    }

    /// 範囲の左上。画素の境目にそろえる (小数のままだと、タイルの縁が半透明に描かれて
    /// 継ぎ目が線になる)。地点は範囲の中心から 1 画素 (0.5pt) までずれる
    var left: Double { floor(centerX - Self.pixelWidth / 2) }
    var top: Double { floor(centerY - Self.pixelHeight / 2) }

    /// 範囲にかかるタイルの番号
    var tiles: [(x: Int, y: Int)] {
        let x0 = Int(floor(left / 256)), x1 = Int(floor((left + Self.pixelWidth - 1) / 256))
        let y0 = Int(floor(top / 256)), y1 = Int(floor((top + Self.pixelHeight - 1) / 256))
        return (y0...y1).flatMap { y in (x0...x1).map { x in (x, y) } }
    }
}

/// 雨雲の地図のタイルを取り、カードを描く。
///
/// CardMaker と同じく、取り直し (`fetch`) と描き直し (`draw`) を分けてある。取った
/// タイルはキャッシュのフォルダ (radar/) に置き、外観が変わったときは取り直さずに描く。
///
/// - 地図のタイル (国土地理院): 陰影起伏図 (海が透明) で陸の形を、白地図で海岸線と
///   都府県の境を取り、外観に合わせて塗り直したものを置いておく。地図は変わらないので
///   30 日使い回す。
/// - 降水のタイル (気象庁): 実況は高解像度降水ナウキャスト (5 分ごとに更新)、予測は
///   降水短時間予報 (10 分ごとに更新、1 時間ごとに 6 時間先まで) の 1 時間後と 3 時間後。
///   ナウキャストの予測は 60 分先までで、300km 四方の地図では雨域がほとんど動いて
///   見えなかった。更新のたびに取り、範囲にかかるタイルは 4×3 枚までなので、1 回に
///   36 枚まで。雨の無いタイルは数百バイトの透明な PNG。降水短時間予報の値は前 1 時間の
///   降水量 (mm) だが、配色はナウキャストの強さ (mm/h) と同じ。
final class RadarMaker {
    let cache: CacheFolder
    let client: JMAClient

    /// 予測のコマ (降水短時間予報の発表の何時間後か)
    static let forecastHours = [1, 3]

    init(cache: CacheFolder, client: JMAClient) {
        self.cache = cache
        self.client = client
    }

    // MARK: - 取り直し

    /// 気象庁のタイルの時刻の一覧 (targetTimes*.json) の 1 件。`member` は降水短時間予報
    /// にだけある (10 分ごとの速報は immed、1 時間ごとの 15 時間先までの予報は none)
    private struct TargetTime: Decodable {
        let basetime: String
        let validtime: String
        let member: String?
    }

    /// 地点のまわりのタイルを取る。実況のタイルを取れたら true
    @discardableResult
    func fetch(latitude: Double, longitude: Double) async -> Bool {
        let decoder = JSONDecoder()
        guard let nowData = await client.data("jmatile/data/nowc/targetTimes_N1.json"),
              let nowTimes = try? decoder.decode([TargetTime].self, from: nowData),
              let nowBase = nowTimes.map(\.basetime).max(),
              let forecastData = await client.data("jmatile/data/rasrf/targetTimes.json"),
              let forecastTimes = try? decoder.decode([TargetTime].self, from: forecastData),
              // 最新の発表時刻には、まだ解析値 (発表時刻と同じ時刻のもの) しか無いことがある
              // (2026-11-18 に 04:20 の発表が解析値だけで、予測は 04:10 の発表にあった)。
              // 予測のある発表のうち、いちばん新しいものを使う
              let forecastBase = forecastTimes.filter({ $0.member == "immed" && $0.validtime > $0.basetime })
                  .map(\.basetime).max(),
              let forecastDate = Self.timeFormatter.date(from: forecastBase) else { return false }
        let valids = Self.forecastHours.map { Self.timeFormatter.string(from: forecastDate.addingTimeInterval(Double($0 * 3600))) }
        let times = RadarTimes(nowBase: nowBase, forecastBase: forecastBase, valids: valids)

        let view = RadarView(latitude: latitude, longitude: longitude)
        let z = RadarView.zoom
        var jobs: [(path: String, file: URL)] = []
        for (x, y) in view.tiles {
            for layer in ["hillshademap", "blank"] {
                let file = cache.radarTile("gsi-\(layer)-\(z)-\(x)-\(y)")
                // 404 (海の上など) は空のファイルにしてあるので、大きさではなく有無で見る
                if FileManager.default.fileExists(atPath: file.path), let age = CacheFolder.age(of: file), age < 30 * 86400 {
                    continue
                }
                jobs.append(("https://cyberjapandata.gsi.go.jp/xyz/\(layer)/\(z)/\(x)/\(y).png", file))
            }
            for frame in times.frames {
                jobs.append((frame.path(x: x, y: y), cache.radarTile(frame.name(x: x, y: y))))
            }
        }
        let client = self.client
        let failed = await withTaskGroup(of: (URL, Bool).self) { group in
            for job in jobs {
                group.addTask { (job.file, await Self.download(job.path, to: job.file, client: client)) }
            }
            var failed: Set<URL> = []
            for await (file, ok) in group where !ok { failed.insert(file) }
            return failed
        }
        let nowTiles = view.tiles.map { cache.radarTile(times.frames[0].name(x: $0.x, y: $0.y)) }
        guard !nowTiles.contains(where: failed.contains) else { return false }
        CacheFolder.writeText(times.line + "\n", to: cache.radarTimes)
        cache.deleteOldFiles(in: "radar", days: 3.0 / 24) { $0.hasPrefix("rain-") }
        cache.deleteOldFiles(in: "radar", days: 30) { $0.hasPrefix("gsi-") || $0.hasPrefix("base-") }
        return true
    }

    /// タイルを取ってファイルに書く。無いタイル (404) は空のファイルにする。
    /// 書けたら true
    private static func download(_ path: String, to file: URL, client: JMAClient) async -> Bool {
        let (data, status) = await client.response(path)
        switch status {
        case 200: return (try? data?.write(to: file, options: .atomic)) != nil
        case 404: return (try? Data().write(to: file, options: .atomic)) != nil
        default: return false
        }
    }

    /// 気象庁のタイルの時刻の書式 (UTC)
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    // MARK: - 描き直し

    /// キャッシュのタイルからサブメニューを作る。地点の実況のタイルが無ければ nil
    func draw(latitude: Double, longitude: Double, dark: Bool) -> RadarCard? {
        guard let line = CacheFolder.readText(cache.radarTimes)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        guard let times = RadarTimes(line: line) else { return nil }
        let view = RadarView(latitude: latitude, longitude: longitude)

        // コマごとに、タイルの番号 → 降水のタイル。予測のタイルが欠けていたら透明として描く
        var frames: [[String: TileBitmap]] = []
        for (k, frame) in times.frames.enumerated() {
            var tiles: [String: TileBitmap] = [:]
            for (x, y) in view.tiles {
                let file = cache.radarTile(frame.name(x: x, y: y))
                if let bitmap = TileBitmap(file: file) {
                    tiles["\(x)-\(y)"] = bitmap
                } else if k == 0, !FileManager.default.fileExists(atPath: file.path) {
                    return nil // 実況のタイルが無い (この地点ではまだ取っていない)
                }
            }
            frames.append(tiles)
        }
        var bases: [String: CGImage] = [:]
        for (x, y) in view.tiles {
            if let image = baseTile(x: x, y: y, dark: dark) { bases["\(x)-\(y)"] = image }
        }

        let report = RadarReport(view: view, frames: frames)
        let card = RadarCardDrawing(view: view, base: times.nowBase, valids: times.valids,
                                    frames: frames, bases: bases, dark: dark).render()
        let page = String(format: "https://www.jma.go.jp/bosai/nowc/#lat:%.6f/lon:%.6f/zoom:9/colordepth:normal/elements:hrpns&slmcs",
                          latitude, longitude)
        let open = L("気象庁の「雨雲の動き」を開く", "Open JMA Rain Radar") + " | sfimage=arrow.up.forward.circle href=\(page)"
        return RadarCard(itemLine: "\(L("雨雲の動き", "Rain Radar"))   \(report.summary) | sfimage=\(report.symbol) href=\(page)",
                         submenuLines: ["--" + SwiftBar.imageLine(card), "--" + open])
    }

    /// 外観に合わせて塗り直した地図のタイル。陰影起伏図で陸と海を塗り分け、白地図の線
    /// (海岸線・都府県の境) を重ねる。作ったものはキャッシュに置く。元のタイルが
    /// まだ無ければ nil (地図の地の色だけで描く)
    private func baseTile(x: Int, y: Int, dark: Bool) -> CGImage? {
        let z = RadarView.zoom
        let file = cache.radarTile("base-\(dark ? "dark" : "light")-\(z)-\(x)-\(y)")
        if let image = TileBitmap(file: file)?.image { return image }
        let hillFile = cache.radarTile("gsi-hillshademap-\(z)-\(x)-\(y)")
        let blankFile = cache.radarTile("gsi-blank-\(z)-\(x)-\(y)")
        guard FileManager.default.fileExists(atPath: hillFile.path),
              FileManager.default.fileExists(atPath: blankFile.path) else { return nil }
        // 空のファイル (404) は、陸も線も無いタイル
        let hill = TileBitmap(file: hillFile)
        let blank = TileBitmap(file: blankFile)
        let palette = MapPalette(dark: dark)
        var out = TileBitmap(width: 256, height: 256)
        for py in 0..<256 {
            for px in 0..<256 {
                var color = palette.sea
                if let hill, px < hill.width, py < hill.height {
                    let p = hill.pixel(px, py)
                    let land = Double(p.alpha) / 255
                    // 陰影 (明るさ) を少しだけ残し、山地を見分けられるようにする
                    let shade = p.alpha > 0 ? Double(p.red) / Double(p.alpha) : 1
                    let relief = palette.land.map { $0 * (1 - palette.relief + palette.relief * shade) }
                    color = zip(color, relief).map { $0 * (1 - land) + $1 * land }
                }
                if let blank, px < blank.width, py < blank.height {
                    let p = blank.pixel(px, py)
                    // 白地図は白地に灰色の線。暗さを線の濃さにする
                    let ink = p.alpha > 0 ? max(0, 1 - Double(p.red) / Double(p.alpha)) * Double(p.alpha) / 255 : 0
                    let strength = min(1, ink * 1.4)
                    color = zip(color, palette.line).map { $0 * (1 - strength) + $1 * strength }
                }
                out.setPixel(px, py, color)
            }
        }
        guard let image = out.image else { return nil }
        out.writePNG(to: file)
        return image
    }
}

/// 雨雲の地図に使う時刻 (気象庁の UTC の書式)。キャッシュの radar/times.txt に
/// 「実況の時刻 予報の発表時刻 予測の時刻…」の 1 行で書く
struct RadarTimes {
    /// 実況 (高解像度降水ナウキャスト) の時刻
    let nowBase: String
    /// 降水短時間予報 (速報) の発表時刻
    let forecastBase: String
    /// 予測のコマの時刻 (`RadarMaker.forecastHours` の順)
    let valids: [String]

    init(nowBase: String, forecastBase: String, valids: [String]) {
        self.nowBase = nowBase
        self.forecastBase = forecastBase
        self.valids = valids
    }

    /// times.txt の 1 行から読む。形が合わなければ nil (v1.2.0 の書式も含む)
    init?(line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count == RadarMaker.forecastHours.count + 2 else { return nil }
        self.init(nowBase: parts[0], forecastBase: parts[1], valids: Array(parts.dropFirst(2)))
    }

    var line: String { ([nowBase, forecastBase] + valids).joined(separator: " ") }

    /// コマ (先頭が実況) のタイルの URL とキャッシュのファイル名
    var frames: [Frame] {
        [Frame(directory: "jmatile/data/nowc/\(nowBase)/none/\(nowBase)/surf/hrpns", stem: "rain-now-\(nowBase)")]
            + valids.map { Frame(directory: "jmatile/data/rasrf/\(forecastBase)/immed/\($0)/surf/rasrf",
                                 stem: "rain-rasrf-\(forecastBase)-\($0)") }
    }

    struct Frame {
        /// タイルの URL の、ズームより前 (JMAClient.base からの相対)
        let directory: String
        /// キャッシュのファイル名の、タイルの番号より前
        let stem: String

        func path(x: Int, y: Int) -> String { "\(directory)/\(RadarView.zoom)/\(x)/\(y).png" }
        func name(x: Int, y: Int) -> String { "\(stem)-\(RadarView.zoom)-\(x)-\(y)" }
    }
}

/// 地図の地の色 (0〜1 の RGB)
struct MapPalette {
    let sea: [Double]
    let land: [Double]
    let line: [Double]
    /// 陰影をどれだけ残すか
    let relief: Double

    init(dark: Bool) {
        // 明るい外観でも地図はやや暗めにする。いちばん弱い雨の色 (#F2F2FF) が白に近く、
        // 白い地では見えない
        if dark {
            sea = Self.rgb(0x1E2733)
            land = Self.rgb(0x4A4A4E)
            line = Self.rgb(0x8E8E93)
        } else {
            sea = Self.rgb(0xA9BED3)
            land = Self.rgb(0xD6D6D8)
            line = Self.rgb(0x77777C)
        }
        relief = 0.25
    }

    private static func rgb(_ value: UInt32) -> [Double] {
        [Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255]
    }
}

/// 降水のタイルから読み取った、地点と地図の範囲の雨の様子
struct RadarReport {
    /// 地点の、コマごとの雨の段階 (降っていなければ nil)
    let center: [Int?]
    /// 実況で、地図の範囲にある雨のいちばん強い段階
    let maxLevel: Int?

    init(view: RadarView, frames: [[String: TileBitmap]]) {
        center = frames.map { Self.level(around: view.centerX, view.centerY, in: $0) }
        maxLevel = frames.first.flatMap { Self.maxLevel(in: view, tiles: $0) }
    }

    /// サブメニューの親の項目に添える文
    var summary: String {
        if let now = center.first, let level = now {
            return L("雨 \(RainLevel.range(level))", "Raining, \(RainLevel.range(level))")
        }
        if let k = center.dropFirst().firstIndex(where: { $0 != nil }) {
            let hours = RadarMaker.forecastHours[k - 1]
            return L("\(hours) 時間後に雨の予測", hours == 1 ? "Rain expected in 1 hour" : "Rain expected in \(hours) hours")
        }
        if let maxLevel {
            return L("周辺に雨雲（最大 \(RainLevel.range(maxLevel))）", "Rain nearby (up to \(RainLevel.range(maxLevel)))")
        }
        return L("雨雲なし", "No rain nearby")
    }

    var symbol: String {
        center.contains { $0 != nil } ? "cloud.rain.circle" : maxLevel != nil ? "cloud.circle" : "sun.max.circle"
    }

    /// 地点のまわり (5×5 画素、約 2.5km 四方) でいちばん強い雨の段階
    private static func level(around x: Double, _ y: Double, in tiles: [String: TileBitmap]) -> Int? {
        var best: Int?
        for dy in -2...2 {
            for dx in -2...2 {
                let gx = Int(floor(x)) + dx, gy = Int(floor(y)) + dy
                let tx = Int(floor(Double(gx) / 256)), ty = Int(floor(Double(gy) / 256))
                guard let tile = tiles["\(tx)-\(ty)"] else { continue }
                let px = gx - tx * 256, py = gy - ty * 256
                guard px < tile.width, py < tile.height else { continue }
                let p = tile.pixel(px, py)
                if let level = RainLevel.level(red: p.red, green: p.green, blue: p.blue, alpha: p.alpha) {
                    best = max(best ?? level, level)
                }
            }
        }
        return best
    }

    private static func maxLevel(in view: RadarView, tiles: [String: TileBitmap]) -> Int? {
        var best: Int?
        let x0 = Int(floor(view.left)), y0 = Int(floor(view.top))
        for (tx, ty) in view.tiles {
            guard let tile = tiles["\(tx)-\(ty)"] else { continue }
            let px0 = max(0, x0 - tx * 256), px1 = min(tile.width, x0 + Int(RadarView.pixelWidth) - tx * 256)
            let py0 = max(0, y0 - ty * 256), py1 = min(tile.height, y0 + Int(RadarView.pixelHeight) - ty * 256)
            guard px0 < px1, py0 < py1 else { continue }
            for py in py0..<py1 {
                for px in px0..<px1 {
                    let p = tile.pixel(px, py)
                    guard p.alpha > 0,
                          let level = RainLevel.level(red: p.red, green: p.green, blue: p.blue, alpha: p.alpha) else { continue }
                    best = max(best ?? level, level)
                }
            }
        }
        return best
    }
}

/// 雨雲の地図のカード。上から見出し・実況の地図・凡例・予測の 3 コマ・出典
struct RadarCardDrawing {
    let view: RadarView
    let base: String
    let valids: [String]
    /// コマごとの降水のタイル (先頭が実況)
    let frames: [[String: TileBitmap]]
    /// 塗り直した地図のタイル
    let bases: [String: CGImage]
    let dark: Bool

    let width: CGFloat = 340
    let headerHeight: CGFloat = 20
    var mapHeight: CGFloat { width * RadarView.pixelHeight / RadarView.pixelWidth }
    let legendHeight: CGFloat = 24
    let thumbnailGap: CGFloat = 8
    var thumbnailWidth: CGFloat { (width - thumbnailGap * CGFloat(valids.count - 1)) / CGFloat(valids.count) }
    var thumbnailHeight: CGFloat { (thumbnailWidth * RadarView.pixelHeight / RadarView.pixelWidth).rounded() }

    func render() -> PNGImage {
        let colors = CardColors(dark: dark)
        let mapTop = headerHeight
        let legendTop = mapTop + mapHeight + 8
        let thumbnailTop = legendTop + legendHeight + 6
        let creditTop = thumbnailTop + thumbnailHeight + 5
        let height = creditTop + 12
        return PNGImage.drawCard(width: width, height: height, dark: dark) { context in
            let pen = WeatherPen(context: context, colors: colors)
            pen.text(L("雨雲の動き", "Rain Radar"), x: 0, y: 0, size: 11, color: colors.secondary)
            pen.text(L("\(Self.clock(base)) の実況", "Observed at \(Self.clock(base))"), x: width, y: 0, size: 11,
                     color: colors.secondary, align: .right)
            drawMap(context, frame: 0, in: CGRect(x: 0, y: mapTop, width: width, height: mapHeight), radius: 6, marker: 5)
            drawLegend(pen, top: legendTop)
            for (i, valid) in valids.enumerated() {
                let rect = CGRect(x: CGFloat(i) * (thumbnailWidth + thumbnailGap), y: thumbnailTop,
                                  width: thumbnailWidth, height: thumbnailHeight)
                drawMap(context, frame: i + 1, in: rect, radius: 5, marker: 4)
                drawThumbnailLabel(context, L("\(RadarMaker.forecastHours[i]) 時間後  \(Self.clock(valid))",
                                              "+\(RadarMaker.forecastHours[i]) h  \(Self.clock(valid))"), in: rect)
            }
            pen.text(L("地理院タイル・気象庁", "GSI Tiles, JMA"), x: width, y: creditTop, size: 9,
                     color: colors.secondary, align: .right)
        }
    }

    /// 地図を `rect` に描く。地図の範囲を `rect` の幅に合わせて縮める
    private func drawMap(_ context: CGContext, frame: Int, in rect: CGRect, radius: CGFloat, marker: CGFloat) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        if let image = mapImage(frame: frame) {
            context.interpolationQuality = .high
            NSImage(cgImage: image, size: rect.size).drawUpright(in: rect)
        }
        context.restoreGState()
        // 地点の印。雨の配色に無い黒と白の二重丸にして、どの色の上でも見えるようにする
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - marker, y: center.y - marker, width: marker * 2, height: marker * 2))
        let inner = marker * 0.55
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
    }

    /// コマの地図を、タイルの画素のまま (680×440) 1 枚に組む。タイルを 1 枚ずつ縮めて
    /// 描くと、縁が透明な外側に溶けて、予測のコマにタイルの継ぎ目が線になって出た
    private func mapImage(frame: Int) -> CGImage? {
        let width = Int(RadarView.pixelWidth), height = Int(RadarView.pixelHeight)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sea = MapPalette(dark: dark).sea
        context.setFillColor(red: sea[0], green: sea[1], blue: sea[2], alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        for (x, y) in view.tiles {
            // Core Graphics の座標は下から上へ取る
            let left = Double(x * 256) - view.left
            let top = Double(y * 256) - view.top
            let tileRect = CGRect(x: left, y: Double(height) - top - 256, width: 256, height: 256)
            let key = "\(x)-\(y)"
            for image in [bases[key], frames[frame][key]?.image].compactMap({ $0 }) {
                context.draw(image, in: tileRect)
            }
        }
        return context.makeImage()
    }

    /// 凡例。段階の色を並べ、境目の下に強さ (mm/h) を書く
    private func drawLegend(_ pen: WeatherPen, top: CGFloat) {
        let unit = "mm/h"
        let unitWidth = ceil(textWidth(unit, font: .card(size: 9))) + 6
        let barWidth = (width - unitWidth) / CGFloat(RainLevel.colors.count)
        for (i, color) in RainLevel.colors.enumerated() {
            pen.context.setFillColor(NSColor(rgb: color).cgColor)
            pen.context.fill(CGRect(x: CGFloat(i) * barWidth, y: top, width: barWidth, height: 6))
        }
        for (i, bound) in RainLevel.bounds.enumerated() {
            pen.text("\(bound)", x: CGFloat(i + 1) * barWidth, y: top + 9, size: 9, color: pen.colors.secondary,
                     digits: .tabular, align: .center)
        }
        pen.text(unit, x: width, y: top + 9, size: 9, color: pen.colors.secondary, align: .right)
    }

    /// 予測のコマの左上に、何分後かを書く。地図の色によらず読めるよう、暗い地を敷く
    private func drawThumbnailLabel(_ context: CGContext, _ text: String, in rect: CGRect) {
        let font = NSFont.card(size: 10, weight: .semibold, digits: .tabular)
        let size = CGSize(width: ceil(textWidth(text, font: font)) + 8, height: 15)
        let pill = CGRect(x: rect.minX + 3, y: rect.minY + 3, width: size.width, height: size.height)
        context.fillRoundedRect(pill, radius: 4, color: NSColor(white: 0, alpha: 0.55))
        drawCardText(text, x: pill.minX + 4, y: pill.minY + 1, font: font, color: .white)
    }

    /// 気象庁の UTC の時刻を、日本時間の「HH:mm」にする
    static func clock(_ text: String) -> String {
        guard let date = RadarMaker.timeFormatter.date(from: text) else { return "" }
        return JapanTime.string(date.timeIntervalSince1970, "H:mm")
    }
}

/// タイルの画素 (sRGB、8 ビットの RGBA、アルファは乗算済み)。行は上から並ぶ
struct TileBitmap {
    let width: Int
    let height: Int
    private var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    /// PNG のファイルを読む。無いか空 (404 だったタイル) か読めなければ nil
    init?(file: URL) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(width: image.width, height: image.height)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = Self.context(buffer.baseAddress, width: width, height: height) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
    }

    func pixel(_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    /// 不透明な色 (0〜1 の RGB) を置く
    mutating func setPixel(_ x: Int, _ y: Int, _ rgb: [Double]) {
        let i = (y * width + x) * 4
        for c in 0..<3 { bytes[i + c] = UInt8(max(0, min(255, (rgb[c] * 255).rounded()))) }
        bytes[i + 3] = 255
    }

    var image: CGImage? {
        var copy = bytes
        return copy.withUnsafeMutableBytes { buffer in
            Self.context(buffer.baseAddress, width: width, height: height)?.makeImage()
        }
    }

    func writePNG(to file: URL) {
        guard let image,
              let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func context(_ data: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
        CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
