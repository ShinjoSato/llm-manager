import Foundation

/// ページの `<title>` をリンクの名前の候補にする。取得は画面側で行い、ここは本文の読み取りだけ。
public enum LinkTitle {
    /// 本文として読む上限（それより後ろの `<title>` は見ない）。
    public static let maxBytes = 256 * 1024

    /// 本文の先頭 `maxBytes` から `<title>…</title>` を抜き、HTML エンティティの基本と空白を整える。無ければ nil。
    public static func parse(_ data: Data) -> String? {
        guard let html = decode(Data(data.prefix(maxBytes))) else { return nil }
        return parse(html: html)
    }

    /// 途中で切った本文を文字にする。UTF-8 の末尾の切れ端は落とし、`<meta charset>` が日本語の文字集合ならそれで読み、どれも無理なら Latin-1。
    static func decode(_ data: Data) -> String? {
        let trimmed = trimmingIncompleteUTF8(data)
        if let utf8 = String(data: trimmed, encoding: .utf8) { return utf8 }
        let ascii = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        var charset = ""
        if let match = ascii.range(of: #"charset=["']?([a-z0-9_-]+)"#, options: .regularExpression) {
            charset = ascii[match].split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? ""
        }
        let encoding: String.Encoding? = switch charset {
        case "shift_jis", "shift-jis", "sjis", "windows-31j", "cp932": .shiftJIS
        case "euc-jp": .japaneseEUC
        case "iso-2022-jp": .iso2022JP
        case "iso-8859-1", "latin1", "windows-1252": .isoLatin1
        default: nil
        }
        if let encoding {
            // 途中で切れた末尾（2 バイト文字の 1 バイト目・エスケープ列）を少しずつ削って読む。
            for drop in 0...3 where data.count > drop {
                if let text = String(data: data.dropLast(drop), encoding: encoding) { return text }
            }
        }
        // UTF-8 の宣言か無宣言は、読めない所を置換文字にして残りを生かす。
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// 末尾がマルチバイト文字の途中で切れていれば、その切れ端（最大 3 バイト）を落とす。
    static func trimmingIncompleteUTF8(_ data: Data) -> Data {
        let bytes = [UInt8](data.suffix(4))
        guard !bytes.isEmpty else { return data }
        // 末尾から継続バイト（10xxxxxx）を数え、その前の先頭バイトが示す長さに足りなければ切れ端。
        var continuation = 0
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0xC0 == 0x80 { continuation += 1; index -= 1 }
        guard index >= 0 else { return data }
        let lead = bytes[index]
        let expected = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        guard expected > 1, continuation < expected - 1 else { return data }
        return data.prefix(data.count - (continuation + 1))
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
