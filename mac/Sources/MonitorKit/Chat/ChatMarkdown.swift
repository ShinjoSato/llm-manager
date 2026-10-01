import Foundation

/// 吹き出しで扱う最低限の Markdown（太字・インラインコード・改行・コードブロック）。
public enum ChatMarkdown {
    public enum Block: Sendable, Equatable {
        case text(String)
        case code(language: String?, String)
    }

    /// ``` で囲まれた部分をコードブロックとして切り出す。閉じていなければ末尾までをコードとみなす。
    public static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var text: [Substring] = []
        var code: [Substring] = []
        var language: String?
        var inCode = false

        func flushText() {
            let joined = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.text(joined)) }
            text = []
        }

        for line in source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: language, code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flushText()
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }
            if inCode { code.append(line) } else { text.append(line) }
        }
        if inCode { blocks.append(.code(language: language, code.joined(separator: "\n"))) }
        flushText()
        return blocks
    }

    /// 段落内のインライン装飾（太字・斜体・コード・リンク）を解釈する。改行はそのまま残す。読めなければ素の文字列。
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
