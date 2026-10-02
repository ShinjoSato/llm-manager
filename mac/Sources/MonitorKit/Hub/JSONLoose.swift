import Foundation

/// JSONSerialization の値を JavaScript の typeof に近い厳しさで読む（NSNumber の 1 を true と取り違えないため）。
enum JSONLoose {
    /// 1 行の JSON を読む。不正な UTF-8 は置換文字に直してから読み直す（Node の toString("utf8") と同じ扱い）。
    static func object(_ bytes: some Collection<UInt8>) -> Any? {
        let data = Data(bytes)
        if let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return o }
        let repaired = Data(String(decoding: data, as: UTF8.self).utf8)
        guard repaired != data else { return nil }
        return try? JSONSerialization.jsonObject(with: repaired, options: [.fragmentsAllowed])
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

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func array(_ v: Any?) -> [Any]? { v as? [Any] }

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
