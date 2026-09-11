// monitor のドメイン型。Claude Code のローカル記録（~/.claude）から組み立てる。
// server/web とは独立したプロセスなので shared/types.ts は参照しない。

/** セッションの状態。hook 由来（正確）と transcript 由来（推定）の両方から決まる。 */
export type SessionStatus =
  | "working" // 稼働中（ツール実行・応答生成）
  | "waiting" // ユーザーの入力待ちで停止
  | "permission" // 権限プロンプトで停止
  | "idle" // 直近の活動が無い
  | "error" // API エラー等で停止
  | "stopped"; // プロセスが終了

export type StatusSource = "hook" | "transcript" | "inventory";

export interface TokenUsage {
  input: number;
  output: number;
  cacheRead: number;
}

/** 親に随伴しているサブエージェント 1 体。 */
export interface AgentInfo {
  id: string;
  /** `developer-plugin:code-reviewer` のような種別。meta.json の agentType から取る。 */
  type: string | null;
  lastActivityAt: number;
}

/** UI に配る 1 セッション分のスナップショット。 */
export interface SessionSnapshot {
  sessionId: string;
  pid: number;
  alive: boolean;
  name: string;
  project: string;
  cwd: string;
  branch: string | null;
  title: string | null;
  lastPrompt: string | null;
  status: SessionStatus;
  statusSource: StatusSource;
  statusDetail: string | null;
  entrypoint: string | null;
  version: string | null;
  startedAt: number;
  lastActivityAt: number | null;
  currentTool: string | null;
  /** 実行中スキルのフルネーム（例 `developer-plugin:dev-done`）。 */
  currentSkill: string | null;
  /** 何をしているかの一行。ツールの description から取る。 */
  currentAction: string | null;
  tokens: TokenUsage | null;
  agents: AgentInfo[];
  /** 受信箱ソケットが見つかっている＝メッセージを送れる。 */
  canReceive: boolean;
  /** Xcode で開ける `.xcworkspace` / `.xcodeproj`。無ければ null。 */
  xcodeProject: string | null;
}

export type FeedKind = "tool" | "prompt" | "message" | "status" | "session" | "agent";

/** ライブフィードの 1 行。 */
export interface FeedItem {
  id: number;
  sessionId: string;
  project: string;
  at: number;
  kind: FeedKind;
  text: string;
  tool: string | null;
}

/** 在庫層が ~/.claude/sessions/<pid>.json から読む生の情報。 */
export interface RawSession {
  pid: number;
  sessionId: string;
  cwd: string;
  startedAt: number;
  name?: string;
  version?: string;
  entrypoint?: string;
  kind?: string;
  /** 受信箱ソケット。ここへ投稿すると、そのセッションにメッセージが届く。 */
  messagingSocketPath?: string;
  alive: boolean;
}

/** フック受け口が受け取るペイロード（Claude Code のフック JSON をそのまま渡す想定）。 */
export interface HookPayload {
  session_id?: string;
  hook_event_name?: string;
  cwd?: string;
  tool_name?: string;
  notification_type?: string;
  notification_message?: string;
  error_type?: string;
  error_message?: string;
  agent_type?: string;
  user_prompt?: string;
  last_assistant_message?: string;
}
