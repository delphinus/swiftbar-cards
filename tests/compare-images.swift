// 描いた画像を、比べる元の画像 (tests/baseline/) と比べる。tests/smoke.sh が使う。
//
//     swift tests/compare-images.swift <比べる元> <描いた画像> <差分の出力先>
//
// 比べる元のフォルダにあるファイルを 1 つずつ、描いた画像のフォルダの同じ名前の
// ファイルと比べる。PNG は画素を、それ以外 (weather のメニューバーの行) は中身を
// そのまま比べる。PNG が違えば、違う画素を赤く塗った画像を差分の出力先に書く。
//
// 画素は、RGBA のどれかが THRESHOLD より大きく違えば「違う」と数え、違う画素が
// 全体の MAX_RATIO を超えたら失敗にする。同じ macOS で描けば画素まで一致するので、
// 許すのは、runner のイメージの更新でアンチエイリアスがわずかにずれる程度に留める
// (曜日 1 つの色が変わっても数百画素になり、失敗になる)。
//
// 結果は tests/smoke.sh と同じ TAP の形 (ok / not ok) で出す。失敗が 1 つでもあれば
// 終了コードを 1 にする。

import AppKit

let threshold = 16
let maxRatio = 0.0002

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write("使い方: compare-images <比べる元> <描いた画像> <差分の出力先>\n".data(using: .utf8)!)
    exit(2)
}
let baseline = URL(fileURLWithPath: arguments[1], isDirectory: true)
let actual = URL(fileURLWithPath: arguments[2], isDirectory: true)
let diffs = URL(fileURLWithPath: arguments[3], isDirectory: true)

/// RGBA (8 ビット、不透明度を乗算済み) の画素の並び
struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init?(contentsOf url: URL) {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.init(width: image.width, height: image.height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    private init(width: Int, height: Int, draw: (CGContext) -> Void) {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(context)
        }
        self.init(width: width, height: height, bytes: bytes)
    }

    func write(to url: URL) {
        var bytes = bytes
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

/// 違う画素の数と、差分の画像 (比べる元を薄くし、違う画素を赤く塗ったもの)
func compare(_ a: Pixels, _ b: Pixels) -> (count: Int, diff: Pixels) {
    var diff = a
    var count = 0
    for i in stride(from: 0, to: a.bytes.count, by: 4) {
        var differs = false
        for c in 0..<4 where abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c])) > threshold { differs = true }
        if differs {
            count += 1
            diff.bytes.replaceSubrange(i..<i + 4, with: [255, 0, 0, 255])
        } else {
            // 白の地に重ねた明るさを薄い灰色にして、どこが違うのかを位置で追えるように
            // する (画素は乗算済みなので、白に重ねると「値 + (255 - 不透明度)」になる)
            let onWhite = (Int(a.bytes[i]) + Int(a.bytes[i + 1]) + Int(a.bytes[i + 2])) / 3 + 255 - Int(a.bytes[i + 3])
            let gray = UInt8(255 - (255 - min(onWhite, 255)) / 4)
            diff.bytes.replaceSubrange(i..<i + 4, with: [gray, gray, gray, 255])
        }
    }
    return (count, diff)
}

let manager = FileManager.default
let names = ((try? manager.contentsOfDirectory(atPath: baseline.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
var failures = 0
func ok(_ message: String) { print("ok - \(message)") }
func ng(_ message: String) {
    print("not ok - \(message)")
    failures += 1
}

if names.isEmpty { ng("比べる元が無い: \(baseline.path)") }
for name in names {
    let expectedFile = baseline.appendingPathComponent(name)
    let actualFile = actual.appendingPathComponent(name)
    guard manager.fileExists(atPath: actualFile.path) else {
        ng("\(name): 描いた画像が無い")
        continue
    }
    guard name.hasSuffix(".png") else {
        if manager.contentsEqual(atPath: expectedFile.path, andPath: actualFile.path) {
            ok(name)
        } else {
            let expected = (try? String(contentsOf: expectedFile, encoding: .utf8)) ?? ""
            let got = (try? String(contentsOf: actualFile, encoding: .utf8)) ?? ""
            ng("\(name): 中身が違う\n#   元:   \(expected.trimmingCharacters(in: .newlines))\n#   今回: \(got.trimmingCharacters(in: .newlines))")
        }
        continue
    }
    guard let a = Pixels(contentsOf: expectedFile), let b = Pixels(contentsOf: actualFile) else {
        ng("\(name): PNG として読めない")
        continue
    }
    guard a.width == b.width, a.height == b.height else {
        ng("\(name): 大きさが違う (元 \(a.width)×\(a.height)、今回 \(b.width)×\(b.height))")
        continue
    }
    let (count, diff) = compare(a, b)
    let ratio = Double(count) / Double(a.width * a.height)
    let summary = String(format: "%d 画素 (%.3f%%) が違う", count, ratio * 100)
    if ratio <= maxRatio {
        ok(count == 0 ? name : "\(name): \(summary) (許す範囲)")
    } else {
        try? manager.createDirectory(at: diffs, withIntermediateDirectories: true)
        diff.write(to: diffs.appendingPathComponent(name))
        ng("\(name): \(summary)")
    }
}
// 比べる元に無い画像は、足し忘れなので知らせる (失敗にはしない)
let actualNames = ((try? manager.contentsOfDirectory(atPath: actual.path)) ?? []).filter { !$0.hasPrefix(".") }
for name in Set(actualNames).subtracting(names).sorted() {
    print("# 比べる元に無い: \(name)")
}
exit(failures == 0 ? 0 : 1)
