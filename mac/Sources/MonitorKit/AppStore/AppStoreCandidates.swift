import Foundation

/// プロジェクトから拾った、紐づけるアプリの手掛かり（`.claude/appstore.json` と Xcode のバンドル ID）。
public struct AppStoreProjectHints: Equatable, Sendable {
    public var configuredAppId: String?
    /// 変数を解決できたバンドル ID。
    public var bundleIdentifiers: [String]
    /// 変数を解決できなかったバンドル ID の書き方（`com.example.$(PRODUCT_NAME)` など）。
    public var bundleTemplates: [String]

    public init(configuredAppId: String? = nil, bundleIdentifiers: [String] = [], bundleTemplates: [String] = []) {
        self.configuredAppId = configuredAppId
        self.bundleIdentifiers = bundleIdentifiers
        self.bundleTemplates = bundleTemplates
    }

    public var isEmpty: Bool { configuredAppId == nil && bundleIdentifiers.isEmpty && bundleTemplates.isEmpty }
}

/// 一覧の中で先に出す候補 1 件と、その理由。
public struct AppStoreCandidate: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        case appStoreJSON
        case bundleID(String)
        case bundleTemplate(String)
    }

    public var app: AppStoreApp
    public var reason: Reason

    public var id: String { app.id }

    public var reasonText: String {
        switch reason {
        case .appStoreJSON: return ".claude/appstore.json の appId"
        case .bundleID(let id): return "バンドル ID が一致（\(id)）"
        case .bundleTemplate(let template): return "バンドル ID の書き方に合う（\(template)）"
        }
    }
}

public enum AppStoreCandidates {
    /// 候補の並び: appstore.json → バンドル ID の一致 → 書き方に合うもの。書き方からの当てはめは 1 件にだけ合う時に限る（誤って当てるより出さない）。
    public static func match(apps: [AppStoreApp], hints: AppStoreProjectHints) -> [AppStoreCandidate] {
        var result: [AppStoreCandidate] = []
        func add(_ app: AppStoreApp, _ reason: AppStoreCandidate.Reason) {
            if !result.contains(where: { $0.app.id == app.id }) { result.append(AppStoreCandidate(app: app, reason: reason)) }
        }
        if let configured = hints.configuredAppId, let app = apps.first(where: { $0.id == configured }) { add(app, .appStoreJSON) }
        for bundle in hints.bundleIdentifiers {
            for app in apps where app.bundleId.caseInsensitiveCompare(bundle) == .orderedSame { add(app, .bundleID(app.bundleId)) }
        }
        for template in hints.bundleTemplates {
            guard let regex = templateRegex(template) else { continue }
            let hits = apps.filter { app in
                app.bundleId.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if hits.count == 1 { add(hits[0], .bundleTemplate(template)) }
        }
        return result
    }

    /// 当てはめに使う変数の数の上限（隣り合う変数は 1 つと数える）。
    static let maxTemplateVariables = 3

    /// 変数の前に「com.example.」のように区切り 2 つ以上の決まった部分がある時だけ、変数を 1 区間以上の英数字・`.`・`-` として当てる。
    static func templateRegex(_ template: String) -> String? {
        let parts = BuildSettingTemplate.split(template)
        guard case .literal(let head)? = parts.first, head.filter({ $0 == "." }).count >= 2, head.first != "." else { return nil }
        var pattern = "^"
        var variables = 0
        var previousWasVariable = false
        for part in parts {
            switch part {
            case .literal(let text):
                pattern += NSRegularExpression.escapedPattern(for: text)
                previousWasVariable = false
            case .variable:
                // 隣り合う変数を別々に当てると照合の手間が膨らむので 1 つにまとめる。
                guard !previousWasVariable else { continue }
                variables += 1
                guard variables <= maxTemplateVariables else { return nil }
                pattern += "[A-Za-z0-9.-]+"
                previousWasVariable = true
            }
        }
        return pattern + "$"
    }

    // MARK: - プロジェクトの走査

    /// 浅く速く: 深さ 4・フォルダ 3,000 個まで、依存・成果物のフォルダと隠しフォルダは見ない、リンクは辿らない。
    static let maxDepth = 4
    static let maxDirectories = 3000
    static let maxProjects = 20
    static let maxConfigs = 50
    static let maxProjectFileBytes = 8 * 1024 * 1024
    static let maxConfigBytes = 256 * 1024
    static let maxJSONBytes = 64 * 1024

    public static func hints(projectPath: String, fileManager: FileManager = .default, isCancelled: () -> Bool = { false }) -> AppStoreProjectHints {
        var hints = AppStoreProjectHints()
        let json = URL(fileURLWithPath: projectPath).appendingPathComponent(".claude/appstore.json")
        if let data = read(json.path, max: maxJSONBytes, fileManager: fileManager) {
            hints.configuredAppId = parseAppStoreJSON(data)
        }
        var pbxprojs: [String] = []
        var configs: [String] = []
        var queue: [(path: String, depth: Int)] = [(projectPath, 0)]
        var head = 0
        while head < queue.count, head < maxDirectories {
            if isCancelled() { break }
            let (dir, depth) = queue[head]
            head += 1
            guard let names = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let type = FilePaths.fileType(path, fileManager: fileManager) else { continue }
                if type == .typeDirectory {
                    let lower = name.lowercased()
                    if lower.hasSuffix(".xcodeproj") {
                        if pbxprojs.count < maxProjects { pbxprojs.append((path as NSString).appendingPathComponent("project.pbxproj")) }
                    } else if depth < maxDepth, !ProjectImages.isSkipped(name), !skippedBundle(lower) {
                        queue.append((path, depth + 1))
                    }
                } else if type == .typeRegular, name.lowercased().hasSuffix(".xcconfig"), configs.count < maxConfigs {
                    configs.append(path)
                }
            }
        }
        var settings: [String: [String]] = [:]
        var templates: [String] = []
        for path in pbxprojs {
            if isCancelled() { return hints }
            guard let data = read(path, max: maxProjectFileBytes, fileManager: fileManager),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for (key, value) in BuildSettingTemplate.pbxprojAssignments(text) {
                if key == "PRODUCT_BUNDLE_IDENTIFIER" { templates.append(value) } else { settings[key, default: []].append(value) }
            }
        }
        for path in configs {
            if isCancelled() { return hints }
            guard let data = read(path, max: maxConfigBytes, fileManager: fileManager),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for (key, value) in BuildSettingTemplate.xcconfigAssignments(text) {
                if key == "PRODUCT_BUNDLE_IDENTIFIER" { templates.append(value) } else { settings[key, default: []].append(value) }
            }
        }
        var resolved: [String] = []
        var unresolved: [String] = []
        var resolver = BuildSettingTemplate.Resolver(settings: settings)
        for template in unique(templates) {
            if isCancelled() { return hints }
            if let values = resolver.resolve(template) {
                resolved += values
            } else {
                unresolved.append(template)
            }
        }
        hints.bundleIdentifiers = unique(resolved)
        hints.bundleTemplates = unique(unresolved)
        return hints
    }

    /// `{"appId": "...", "platform": "IOS"}` の appId（数でもよい）。形が違えば無いものとして読む。
    static func parseAppStoreJSON(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var appId: String?
        if let text = object["appId"] as? String {
            appId = text.trimmingCharacters(in: .whitespaces)
        } else if let number = object["appId"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            appId = number.stringValue
        }
        if let id = appId, !AppStoreRequest.isAppID(id) { appId = nil }
        return appId
    }

    private static func skippedBundle(_ lower: String) -> Bool {
        [".xcworkspace", ".xcassets", ".app", ".framework", ".xcframework", ".bundle", ".playground"].contains { lower.hasSuffix($0) }
    }

    private static func read(_ path: String, max: Int, fileManager: FileManager) -> Data? {
        guard FilePaths.fileType(path, fileManager: fileManager) == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data: Data?
        do { data = try handle.read(upToCount: max + 1) } catch { return nil }
        guard let data, data.count <= max else { return nil }
        return data
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Xcode のビルド設定の値（`$(NAME)` / `${NAME}` を含む）の読み取りと解決。
enum BuildSettingTemplate {
    enum Part: Equatable {
        case literal(String)
        case variable(name: String, modifier: String?)
    }

    /// 解決の候補の数の上限（値が複数ある変数の組み合わせが膨らまないように）。
    static let maxResults = 8
    static let maxDepth = 4

    static func split(_ template: String) -> [Part] {
        var parts: [Part] = []
        var literal = ""
        var index = template.startIndex
        while index < template.endIndex {
            let char = template[index]
            let next = template.index(after: index)
            if char == "$", next < template.endIndex, template[next] == "(" || template[next] == "{" {
                let close: Character = template[next] == "(" ? ")" : "}"
                if let end = template[next...].firstIndex(of: close) {
                    let inner = String(template[template.index(after: next)..<end])
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    let pieces = inner.split(separator: ":", maxSplits: 1).map(String.init)
                    parts.append(.variable(name: pieces.first ?? "", modifier: pieces.count > 1 ? pieces[1] : nil))
                    index = template.index(after: end)
                    continue
                }
            }
            literal.append(char)
            index = next
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        return parts
    }

    /// すべての変数を決まった値にできた時だけ返す（できなければ nil）。
    static func resolve(_ template: String, settings: [String: [String]]) -> [String]? {
        var resolver = Resolver(settings: settings)
        return resolver.resolve(template)
    }

    /// 値の重複を除き、変数ごとの解決を覚えて使い回す（互いに参照し合う設定で呼び出しが膨らまないため）。辿っている途中の変数に戻れば解決できないとする。
    struct Resolver {
        private let settings: [String: [String]]
        private var memo: [String: [String]?] = [:]
        private var resolving: Set<String> = []

        init(settings: [String: [String]]) {
            var unique: [String: [String]] = [:]
            for (name, values) in settings {
                var seen = Set<String>()
                unique[name] = values
                    .map { $0.replacingOccurrences(of: "$(inherited)", with: "").trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && seen.insert($0).inserted }
            }
            self.settings = unique
        }

        mutating func resolve(_ template: String, depth: Int = 0) -> [String]? {
            guard depth <= BuildSettingTemplate.maxDepth else { return nil }
            var results = [""]
            for part in BuildSettingTemplate.split(template) {
                switch part {
                case .literal(let text):
                    results = results.map { $0 + text }
                case .variable(let name, let modifier):
                    guard let values = variable(name, depth: depth) else { return nil }
                    var applied: [String] = []
                    for value in values {
                        guard let item = BuildSettingTemplate.apply(modifier, to: value) else { return nil }
                        if !applied.contains(item) { applied.append(item) }
                    }
                    results = results.flatMap { prefix in applied.map { prefix + $0 } }
                    if results.count > BuildSettingTemplate.maxResults { return nil }
                }
            }
            return results
        }

        private mutating func variable(_ name: String, depth: Int) -> [String]? {
            if let known = memo[name] { return known }
            guard !resolving.contains(name), let raw = settings[name], !raw.isEmpty else { return nil }
            resolving.insert(name)
            var values: [String] = []
            for value in raw {
                guard let expanded = resolve(value, depth: depth + 1) else { continue }
                for item in expanded where !values.contains(item) { values.append(item) }
                if values.count > BuildSettingTemplate.maxResults { break }
            }
            resolving.remove(name)
            let result: [String]? = values.isEmpty || values.count > BuildSettingTemplate.maxResults ? nil : values
            memo[name] = .some(result)
            return result
        }
    }

    static func apply(_ modifier: String?, to value: String) -> String? {
        switch modifier {
        case nil: return value
        case "lower": return value.lowercased()
        case "upper": return value.uppercased()
        case "rfc1034identifier":
            return String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") ? $0 : "-" })
        default: return nil
        }
    }

    /// pbxproj の `NAME = value;` の行（名前は大文字・数字・`_`）。
    static func pbxprojAssignments(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(";"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard isSettingName(key) else { continue }
            var value = trimmed[trimmed.index(after: eq)...].dropLast().trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { result.append((key, value)) }
        }
        return result
    }

    /// xcconfig の `NAME = value`（`//` 以降と `#include` は飛ばす。`NAME[sdk=…]` の条件付きも値の候補にする）。
    static func xcconfigAssignments(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }
            if let comment = trimmed.range(of: "//") { trimmed = String(trimmed[..<comment.lowerBound]) }
            // 条件付きの `NAME[sdk=iphoneos*][config=Debug] = v` は条件の中にも `=` があるので、続く `[…]` を飛ばした後の `=` で分ける。
            var searchFrom = trimmed.firstIndex { $0 == "[" || $0 == "=" } ?? trimmed.endIndex
            var broken = false
            while searchFrom < trimmed.endIndex, trimmed[searchFrom] == "[" {
                guard let close = trimmed[searchFrom...].firstIndex(of: "]") else {
                    broken = true
                    break
                }
                searchFrom = trimmed.index(after: close)
                while searchFrom < trimmed.endIndex, trimmed[searchFrom] == " " { searchFrom = trimmed.index(after: searchFrom) }
            }
            guard !broken, let eq = trimmed[searchFrom...].firstIndex(of: "=") else { continue }
            var key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]).trimmingCharacters(in: .whitespaces) }
            guard isSettingName(key) else { continue }
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { result.append((key, value)) }
        }
        return result
    }

    private static func isSettingName(_ text: String) -> Bool {
        guard let first = text.first, first.isASCII, first.isUppercase else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }
}
