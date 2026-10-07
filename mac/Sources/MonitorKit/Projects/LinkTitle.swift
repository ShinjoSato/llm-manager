import Foundation

/// ページの `<title>` をリンクの名前の候補にする。取得は画面側で行い、ここは本文の読み取りだけ。
public enum LinkTitle {
    /// 本文として読む上限（それより後ろの `<title>` は見ない）。
    public static let maxBytes = 256 * 1024

    /// 本文の先頭 `maxBytes` から `<title>…</title>` を抜き、HTML エンティティの基本と空白を整える。無ければ nil。
    public static func parse(_ data: Data) -> String? {
        let head = data.prefix(maxBytes)
        guard let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        return parse(html: html)
    }

    public static func parse(html: String) -> String? {
        guard let match = html.range(of: #"<title(?:\s[^>]*)?>([\s\S]*?)</title\s*>"#, options: [.regularExpression, .caseInsensitive]),
              let open = html.range(of: ">", range: match),
              let close = html.range(of: "</title", options: [.caseInsensitive, .backwards], range: match) else { return nil }
        let raw = String(html[open.upperBound..<close.lowerBound])
        let text = collapseWhitespace(decodeEntities(raw))
        return text.isEmpty ? nil : text
    }

    /// `&amp;` 等の名前付きと `&#NNN;` / `&#xHH;` の数値参照を戻す。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let tail = rest[amp...]
            guard let semi = tail.firstIndex(of: ";"), tail.distance(from: amp, to: semi) <= 10,
                  let decoded = entity(String(tail[tail.index(after: amp)..<semi])) else {
                result.append("&")
                rest = tail.dropFirst()
                continue
            }
            result += decoded
            rest = tail[tail.index(after: semi)...]
        }
        return result + rest
    }

    private static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
