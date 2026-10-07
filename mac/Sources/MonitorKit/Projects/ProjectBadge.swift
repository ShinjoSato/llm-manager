import AppKit
import Foundation
import os

/// プロジェクトの印の色。settings.json の `color` のキーで、並びは設定画面のスウォッチとパレットの順。
public enum ProjectColor: String, CaseIterable, Sendable, Identifiable {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink, brown, gray

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .red: return "赤"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "緑"
        case .teal: return "青緑"
        case .blue: return "青"
        case .indigo: return "藍"
        case .purple: return "紫"
        case .pink: return "桃"
        case .brown: return "茶"
        case .gray: return "灰"
        }
    }

    /// パレットの中の位置（`ThemePalette.avatarPalette` と同じ順）。
    public var paletteIndex: Int { ProjectColor.allCases.firstIndex(of: self)! }

    /// 名前のハッシュで既定を引く候補。キーを足す前の 8 色の並びのままにして、未設定のプロジェクトの色を変えない。
    public static let hashCandidates: [ProjectColor] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .red]
}

/// 一覧・詳細の見出し・「+」の一覧で使うプロジェクトの印（色のキーと SF Symbol 名）。
public struct ProjectBadge: Equatable, Sendable {
    public var colorKey: ProjectColor
    public var symbol: String

    public init(colorKey: ProjectColor, symbol: String) {
        self.colorKey = colorKey
        self.symbol = symbol
    }

    /// アイコンが無い・解決できない時の SF Symbol。
    public static let defaultSymbol = "folder"

    /// 設定画面のグリッドに出す候補（用途別）。
    public static let symbolChoices: [String] = [
        "folder", "app", "iphone", "laptopcomputer", "globe", "server.rack", "terminal", "hammer",
        "wrench", "paintbrush", "book", "doc.text", "chart.bar", "creditcard", "cart", "bag",
        "gamecontroller", "music.note", "camera", "photo", "film", "map", "car", "airplane",
        "house", "building.2", "leaf", "flame", "star", "heart", "bolt", "shield",
        "lock", "key", "flag", "bell", "tag", "gift", "graduationcap", "briefcase",
    ]

    /// 名前から決める既定の色。
    public static func defaultColor(for name: String) -> ProjectColor {
        ProjectColor.hashCandidates[RoomGrouping.colorIndex(for: name, paletteSize: ProjectColor.hashCandidates.count)]
    }

    /// 設定から印を決める。知らない色は名前から、空・無い Symbol は既定に落とす。
    public static func resolve(project: ManagedProject, symbolExists: (String) -> Bool = ProjectBadge.symbolExists) -> ProjectBadge {
        let colorKey = project.color.flatMap(ProjectColor.init(rawValue:)) ?? defaultColor(for: project.name)
        let icon = project.icon?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let symbol = !icon.isEmpty && symbolExists(icon) ? icon : defaultSymbol
        return ProjectBadge(colorKey: colorKey, symbol: symbol)
    }

    private static let knownSymbols = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// SF Symbol として解決できるか（結果は覚えておき、一覧の描き直しのたびに引かない）。
    public static func symbolExists(_ name: String) -> Bool {
        if let known = knownSymbols.withLock({ $0[name] }) { return known }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        knownSymbols.withLock { $0[name] = exists }
        return exists
    }

    /// `color` の問題（無ければ nil）。知らない値は警告にして、表示は既定に落とす。
    public static func colorProblem(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if ProjectColor(rawValue: raw) != nil { return nil }
        return "色「\(raw)」は知らない値です（\(ProjectColor.allCases.map(\.rawValue).joined(separator: " / ")) のいずれか）。名前から決めた色で出します"
    }

    /// `icon` の問題（無ければ nil）。空は警告にして、表示は既定に落とす。
    public static func iconProblem(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "アイコンが空です（SF Symbol の名前を書くか、キーを消してください）。既定の \(defaultSymbol) で出します" : nil
    }
}
