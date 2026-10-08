import AppKit
import MonitorKit
import SwiftUI
import UniformTypeIdentifiers

/// 書き出し・読み込み: settings.json と同じ形で書き出し、旧 TSV や書き出したものを取り込む。
struct TransferSettingsTab: View {
    let store: SettingsStore
    @State private var exportMessage: String?
    @State private var importMessage: String?
    @State private var importFailed = false

    /// 取り込むファイルの上限（設定にしては大きすぎるものを読まない）。
    private static let maxImportBytes = 4 * 1024 * 1024

    var body: some View {
        Form {
            Section("設定ファイル") {
                LabeledContent("場所") {
                    Text(store.file.url.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Finder で表示") { SystemActions.revealInFinder(store.file.url) }
                }
                if let error = store.saveError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                HStack {
                    Text("今の設定を settings.json と同じ形で保存します。")
                    Spacer()
                    Button("書き出す…") { export() }
                }
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("書き出し")
            }
            Section {
                HStack {
                    Text("選んだファイルから足りないものだけを足します。")
                    Spacer()
                    Button("読み込む…") { importFile() }
                        .disabled(!store.isEditable)
                }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(importFailed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("読み込み")
            } footer: {
                Text("""
                読めるのは registry.tsv（name / path / status / note）・github-projects.tsv（name / owner / number / repo / url）・\
                書き出した settings.json です。形式は中身から判断します。既にあるプロジェクト（同じパス）・GitHub の紐づけ（同じ名前のプロジェクト）・\
                ボード（同じ owner と番号）は上書きしません。旧 TSV は registry.tsv → github-projects.tsv の順に読み込んでください。
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "claude-deck-settings.json"
        panel.prompt = "書き出す"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url, options: .atomic)
            exportMessage = "\(url.lastPathComponent) に書き出しました"
        } catch {
            exportMessage = "書き出せませんでした: \(error.localizedDescription)"
        }
    }

    private func importFile() {
        guard let url = SystemActions.choose(folders: false, multiple: false, prompt: "読み込む").first else { return }
        importFailed = true
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxImportBytes,
              let data = try? Data(contentsOf: url) else {
            importMessage = "\(url.lastPathComponent) を読めませんでした（大きすぎるか、読む権限がありません）"
            return
        }
        do {
            let summary = try store.importData(data)
            importFailed = false
            importMessage = "\(url.lastPathComponent): \(summary.message)"
        } catch let failure as SettingsImport.Failure {
            importMessage = "\(url.lastPathComponent): \(failure.message)"
        } catch {
            importMessage = "\(url.lastPathComponent): 取り込めませんでした"
        }
    }
}
