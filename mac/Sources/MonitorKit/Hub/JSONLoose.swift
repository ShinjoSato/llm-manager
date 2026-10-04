import Foundation

/// JSONSerialization の値を JavaScript の typeof に近い厳しさで読む（NSNumber の 1 を true と取り違えないため）。
enum JSONLoose {
    /// 1 行の JSON を読む。不正な UTF-8 は置換文字に直してから読み直す（Node の toString("utf8") と同じ扱い）。
    static func object(_ bytes: some Collection<UInt8>) -> Any? {
        let data = Data(bytes)
        if let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return o }
        // JSONSerialization は対になっていないサロゲートのエスケープを弾くが、JSON.parse は通すので置換文字にして読む。
        let repaired = replacingLoneSurrogates(Data(String(decoding: data, as: UTF8.self).utf8))
        guard repaired != data else { return nil }
        return try? JSONSerialization.jsonObject(with: repaired, options: [.fragmentsAllowed])
    }

    /// `\uD800`〜`\uDFFF` のうち対になっていないエスケープを `\uFFFD` に置き換える。
    static func replacingLoneSurrogates(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.contains(0x5C) else { return data }
        func hex(_ at: Int) -> UInt16? {
            guard at + 4 <= bytes.count else { return nil }
            var value: UInt16 = 0
            for b in bytes[at..<(at + 4)] {
                let digit: UInt8
                switch b {
                case 0x30...0x39: digit = b - 0x30
                case 0x41...0x46: digit = b - 0x41 + 10
                case 0x61...0x66: digit = b - 0x61 + 10
                default: return nil
                }
                value = value << 4 | UInt16(digit)
            }
            return value
        }
        func unicodeEscape(_ at: Int) -> UInt16? {
            guard at + 1 < bytes.count, bytes[at] == 0x5C, bytes[at + 1] == 0x75 else { return nil }
            return hex(at + 2)
        }
        let replacement = Array("\\uFFFD".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == 0x5C, i + 1 < bytes.count else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard let unit = unicodeEscape(i) else {
                // `\\` 等は 2 バイトで 1 つ。後ろの `u` を別のエスケープと読み違えないよう一緒に送る。
                out.append(contentsOf: bytes[i...(i + 1)])
                i += 2
                continue
            }
            switch unit {
            case 0xD800...0xDBFF:
                if let low = unicodeEscape(i + 6), (0xDC00...0xDFFF).contains(low) {
                    out.append(contentsOf: bytes[i..<(i + 12)])
                    i += 12
                } else {
                    out.append(contentsOf: replacement)
                    i += 6
                }
            case 0xDC00...0xDFFF:
                out.append(contentsOf: replacement)
                i += 6
            default:
                out.append(contentsOf: bytes[i..<(i + 6)])
                i += 6
            }
        }
        return Data(out)
    }

    static func string(_ v: Any?) -> String? { v as? String }

    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func isTrue(_ v: Any?) -> Bool {
        isBool(v) && (v as! NSNumber).boolValue
    }

    /// 数値（真偽値を除く）。有限でなければ nil。
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBool(n) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// JavaScript の `Number(v) || 0` 相当（数値と数字だけの文字列を受ける）。
    static func coerceNumber(_ v: Any?) -> Double {
        if let d = number(v) { return d }
        if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
        return 0
    }

    /// 有限の数を Int に丸める。範囲外は端に寄せる（`Int(Double)` は範囲外でトラップするため）。
    static func clampedInt(_ d: Double) -> Int {
        guard d.isFinite else { return 0 }
        if d >= Double(Int.max) { return Int.max }
        if d <= Double(Int.min) { return Int.min }
        return Int(d)
    }

    /// 個数として読む（負・数でないものは 0）。
    static func count(_ v: Any?) -> Int {
        max(0, clampedInt(coerceNumber(v)))
    }

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }

    /// `Date.parse(timestamp) || null`（epoch ミリ秒）。
    static func timestamp(_ v: Any?) -> Double? {
        guard let s = v as? String else { return nil }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? withFraction.parse(s) { return nonZero(d) }
        if let d = try? Date.ISO8601FormatStyle().parse(s) { return nonZero(d) }
        return nil
    }

    private static func nonZero(_ d: Date) -> Double? {
        let ms = (d.timeIntervalSince1970 * 1000).rounded()
        return ms == 0 ? nil : ms
    }
}

/// バイト列の検索（行の絞り込みを JSON 化の前に安く済ませる）。
enum Bytes {
    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count, let base = haystack.baseAddress else { return needle.isEmpty }
        return needle.withUnsafeBytes { n in memmem(base, haystack.count, n.baseAddress, n.count) != nil }
    }

    static func contains(_ haystack: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { contains($0, needle) }
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { contains($0, needle) }
    }

    /// ファイルの `offset` から `length` バイト読む。読めなければ nil。
    static func read(_ path: String, offset: Int, length: Int) -> [UInt8]? {
        guard length >= 0 else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out = [UInt8](repeating: 0, count: length)
        var done = 0
        while done < length {
            let n = out.withUnsafeMutableBytes { buf in
                pread(fd, buf.baseAddress! + done, length - done, off_t(offset + done))
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            done += n
        }
        if done < length { out.removeSubrange(done...) }
        return out
    }

    /// ファイルサイズ。無ければ nil。
    static func size(_ path: String) -> Int? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Int(st.st_size)
    }
}

/// 現在時刻（epoch ミリ秒）。
@Sendable public func epochMillisNow() -> Double {
    (Date().timeIntervalSince1970 * 1000).rounded()
}
