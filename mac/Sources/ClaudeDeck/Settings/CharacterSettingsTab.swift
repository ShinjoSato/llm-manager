import MonitorKit
import SwiftUI

/// キャラクター: ルーム一覧のドット絵とステージの 3D を、状態・職業ごとに見本で並べる（見るだけ）。
struct CharacterSettingsTab: View {
    @State private var stageStatus: SessionStatus = .working
    /// サブエージェントの組の番号。-1 は立てない。
    @State private var jobPage = 0
    @State private var tool = CharacterGallery.items[0].tool

    private static let jobPages = CharacterGallery.jobPages()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pixelSection
                stageSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 2D

    private var pixelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2D（ルーム一覧・会話の見出し）").font(.headline)
            Text("状態ごとの絵。動きはルーム一覧と同じです（動きを減らす設定では止まります）。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 14) {
                ForEach(CharacterGallery.statuses, id: \.self) { status in
                    VStack(spacing: 6) {
                        PixelAvatar(status: status, size: 56)
                        Text(ChatTheme.label(for: status))
                            .font(ChatTheme.caption)
                            .foregroundStyle(ChatTheme.text)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ChatTheme.label(for: status))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(ChatTheme.sidebar))
        }
    }

    // MARK: - 3D

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3D（ステージ）").font(.headline)
            Text("ステージと同じ組み立てで、見本のセッションを描きます。持ち物は稼働中の時だけ持ちます。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("状態", selection: $stageStatus) {
                ForEach(CharacterGallery.statuses, id: \.self) { status in
                    Text(ChatTheme.label(for: status)).tag(status)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 16) {
                Picker("サブエージェント", selection: $jobPage) {
                    Text("なし").tag(-1)
                    ForEach(Self.jobPages.indices, id: \.self) { index in
                        Text(Self.jobPages[index].map(\.job.label).joined(separator: "・")).tag(index)
                    }
                }
                Picker("持ち物", selection: $tool) {
                    ForEach(CharacterGallery.items) { item in
                        Text(item.label).tag(item.tool)
                    }
                }
                .disabled(stageStatus != .working)
                .frame(maxWidth: 200)
            }
            StageSceneView(model: CharacterGallery.model(status: stageStatus, jobs: shownJobs, tool: tool))
                .aspectRatio(332.0 / 230.0, contentMode: .fit)
                .frame(maxWidth: 460)
                .background(RoundedRectangle(cornerRadius: 10).fill(ChatTheme.stagePanel))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("ステージの見本（\(ChatTheme.label(for: stageStatus))）")
            jobLegend
        }
    }

    private var shownJobs: [CharacterJobSample] {
        Self.jobPages.indices.contains(jobPage) ? Self.jobPages[jobPage] : []
    }

    /// 職業ごとの配色と役割。ステージに立っている組を強調する。
    private var jobLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("職業（サブエージェント）").font(.subheadline.weight(.semibold))
            ForEach(CharacterGallery.jobs) { sample in
                let shown = shownJobs.contains(sample)
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(hex: sample.job.light)).frame(width: 12, height: 12)
                        RoundedRectangle(cornerRadius: 2).fill(Color(hex: sample.job.dark)).frame(width: 12, height: 12)
                    }
                    .accessibilityHidden(true)
                    Text(sample.job.label).font(.callout.weight(shown ? .semibold : .regular)).frame(width: 84, alignment: .leading)
                    Text(sample.roles.joined(separator: "／")).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(sample.types.isEmpty ? "（種別不明）" : sample.types.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(sample.types.joined(separator: "\n"))
                }
                .opacity(shown || shownJobs.isEmpty ? 1 : 0.55)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
