import Foundation

/// LRC 歌词解析（Apple Music 风格歌词页使用）。
struct LrcLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

enum LrcParser {

    /// 解析 LRC 文本为按时间排序的行；支持一行多个时间标签 `[mm:ss.xx][mm:ss.xx]文本`。
    static func parse(_ text: String) -> [LrcLine] {
        var lines: [(time: Double, text: String)] = []
        let tagRegex = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]")
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let regex = tagRegex else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let content = ns.substring(from: matches.last!.range.upperBound)
                    .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, content.hasPrefix("[") == false || matches.first!.range.lowerBound == 0 else {
                continue
            }
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                // 可选分组未参与匹配时 range(at:) 返回 {NSNotFound, 0}，
                // 直接 substring 会抛 NSRangeException，必须先判断。
                let r3 = m.range(at: 3)
                let fracStr = (r3.location != NSNotFound && r3.location != 0)
                    ? ns.substring(with: r3) : ""
                let frac: Double
                if fracStr.isEmpty {
                    frac = 0
                } else if fracStr.count == 1 {
                    frac = (Double(fracStr) ?? 0) / 10
                } else if fracStr.count == 2 {
                    frac = (Double(fracStr) ?? 0) / 100
                } else {
                    frac = (Double(fracStr) ?? 0) / 1000
                }
                lines.append((mm * 60 + ss + frac, content))
            }
        }
        return lines
            .sorted { $0.time < $1.time }
            .enumerated()
            .map { LrcLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }

    /// 二分查找当前播放时间对应的行下标（无命中返回 -1）。
    static func currentIndex(of lines: [LrcLine], at time: Double) -> Int {
        guard !lines.isEmpty, time >= lines[0].time else { return -1 }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
