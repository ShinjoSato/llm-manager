// 在庫層・実況層・フック層を 1 つの状態に束ね、変化を購読者へ流す。
import { EventEmitter } from "node:events";
import { existsSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import { scanSessions } from "./inventory.js";
import { resolveTranscript, subagentDir } from "./paths.js";
import { primeMeta, TranscriptReader } from "./transcript.js";
import type {
  FeedItem,
  FeedKind,
  HookPayload,
  RawSession,
  SessionSnapshot,
  SessionStatus,
  StatusSource,
  TokenUsage,
} from "./types.js";

/**
 * ログが「モデルの番」で終わったまま、この時間を超えて無音なら稼働中とみなさない。
 * 中断やクラッシュで tool_use が最後のまま残ったセッションを永久に稼働中にしないための保険。
 */
const STALE_BUSY_MS = 10 * 60_000;
/** サブエージェントのログがこの時間内に更新されていれば、そのエージェントは動いているとみなす。 */
const AGENT_WINDOW_MS = 3 * 60_000;
/** 終了したセッションを一覧に残す時間。消えた理由を追えるようにする。 */
const STOPPED_RETENTION_MS = 5 * 60_000;
const INVENTORY_INTERVAL_MS = 3_000;
const TRANSCRIPT_INTERVAL_MS = 250;
/** サブエージェント数の走査は syscall が多いので実況ポーリングより粗くする。 */
const AGENT_SCAN_INTERVAL_MS = 2_000;
const FEED_LIMIT = 300;

interface SessionState {
  raw: RawSession;
  reader: TranscriptReader | null;
  transcriptPath: string | null;
  branch: string | null;
  title: string | null;
  lastPrompt: string | null;
  lastActivityAt: number | null;
  currentTool: string | null;
  recentTools: string[];
  tokens: TokenUsage | null;
  hookStatus: SessionStatus | null;
  hookDetail: string | null;
  hookAt: number;
  activeAgents: number;
  agentsCheckedAt: number;
  /** サブエージェントのログが最後に動いた時刻。親が Agent 実行中は親ログが無音になるため。 */
  lastAgentActivityAt: number | null;
  endedAt: number | null;
  turnState: TurnState | null;
}

/**
 * ログの終わり方。busy はモデルの番（ツール実行中・長考中）で、無音でも動いている。
 * ツール実行や思考の間はログが数分書かれないため、経過時間だけでは稼働を判定できない。
 */
type TurnState = "busy" | "settled";

export class SessionHub extends EventEmitter {
  private sessions = new Map<string, SessionState>();
  private feed: FeedItem[] = [];
  private feedSeq = 0;
  private timers: NodeJS.Timeout[] = [];

  start(): void {
    this.guard(() => this.scanInventory());
    this.guard(() => this.pollTranscripts());
    this.timers.push(
      setInterval(() => this.guard(() => this.scanInventory()), INVENTORY_INTERVAL_MS),
    );
    this.timers.push(
      setInterval(() => this.guard(() => this.pollTranscripts()), TRANSCRIPT_INTERVAL_MS),
    );
  }

  stop(): void {
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
  }

  /** 監視ループの例外でプロセスごと落とさない。 */
  private guard(fn: () => void): void {
    try {
      fn();
    } catch (err) {
      console.error("[monitor] poll error:", err);
    }
  }

  // ── 在庫層 ────────────────────────────────────────
  private scanInventory(): void {
    const seen = new Set<string>();
    const now = Date.now();
    let changed = false;

    for (const raw of scanSessions()) {
      seen.add(raw.sessionId);
      const existing = this.sessions.get(raw.sessionId);
      if (!existing) {
        this.sessions.set(raw.sessionId, this.createState(raw));
        changed = true;
        this.push(raw.sessionId, "session", `セッション検出: ${basename(raw.cwd)}`);
        continue;
      }
      if (existing.raw.alive !== raw.alive) {
        changed = true;
        if (!raw.alive) this.push(raw.sessionId, "session", "セッション終了");
      }
      existing.raw = raw;
      existing.endedAt = raw.alive ? null : (existing.endedAt ?? now);
    }

    // レジストリから消えたセッションは終了済み。しばらく墓標として残してから捨てる。
    for (const [id, state] of this.sessions) {
      if (seen.has(id)) continue;
      if (state.endedAt === null) {
        state.endedAt = now;
        state.raw = { ...state.raw, alive: false };
        this.push(id, "session", "セッション終了");
        changed = true;
      } else if (now - state.endedAt > STOPPED_RETENTION_MS) {
        this.sessions.delete(id);
        changed = true;
      }
    }

    if (changed) this.emitUpdate();
  }

  private createState(raw: RawSession): SessionState {
    const transcriptPath = resolveTranscript(raw.sessionId, raw.cwd);
    const meta = transcriptPath ? primeMeta(transcriptPath) : {};
    return {
      raw,
      transcriptPath,
      reader: transcriptPath ? new TranscriptReader(transcriptPath) : null,
      branch: null,
      title: meta.title ?? null,
      lastPrompt: meta.lastPrompt ?? null,
      lastActivityAt: null,
      currentTool: null,
      recentTools: [],
      tokens: null,
      hookStatus: null,
      hookDetail: null,
      hookAt: 0,
      activeAgents: 0,
      agentsCheckedAt: 0,
      lastAgentActivityAt: null,
      endedAt: raw.alive ? null : Date.now(),
      turnState: null,
    };
  }

  // ── 実況層 ────────────────────────────────────────
  private pollTranscripts(): void {
    const now = Date.now();
    let changed = false;

    for (const [id, state] of this.sessions) {
      if (!state.reader) {
        // 起動直後はログがまだ無いことがあるので都度あきらめずに探す。
        const path = resolveTranscript(state.raw.sessionId, state.raw.cwd);
        if (!path) continue;
        state.transcriptPath = path;
        state.reader = new TranscriptReader(path);
        const meta = primeMeta(path);
        state.title = state.title ?? meta.title ?? null;
        state.lastPrompt = state.lastPrompt ?? meta.lastPrompt ?? null;
      }

      const events = state.reader.read();
      if (events.length) changed = true;

      for (const ev of events) {
        if (ev.branch) state.branch = ev.branch;
        if (ev.title && ev.title !== state.title) {
          state.title = ev.title;
          this.push(id, "message", `作業内容: ${ev.title}`);
        }
        if (ev.lastPrompt && ev.lastPrompt !== state.lastPrompt) {
          state.lastPrompt = ev.lastPrompt;
          this.push(id, "prompt", truncate(ev.lastPrompt, 160));
        }
        if (ev.at) state.lastActivityAt = Math.max(state.lastActivityAt ?? 0, ev.at);
        if (ev.usage) state.tokens = ev.usage;

        // thinking だけの assistant 行では判定を変えない（応答が終わったとは限らない）。
        if (ev.type === "assistant") {
          if (ev.tools?.length) state.turnState = "busy";
          else if (ev.text) state.turnState = "settled";
        } else if (ev.type === "user") {
          state.turnState = "busy"; // プロンプト送信か tool_result。どちらも次はモデルの番
        }

        if (ev.tools?.length) {
          state.currentTool = ev.tools[ev.tools.length - 1] ?? null;
          state.recentTools = [...state.recentTools, ...ev.tools].slice(-12);
          for (const tool of ev.tools) this.push(id, "tool", tool, tool);
          // フックより新しい行を読んだ時だけ「待ち」を解く。古い行で権限待ちを消さない。
          if (!ev.at || ev.at > state.hookAt) {
            state.hookStatus = null;
            state.hookDetail = null;
          }
        } else if (ev.type === "user") {
          state.currentTool = null; // tool_result が返った = ツールは終わっている
        } else if (ev.type === "assistant" && ev.text) {
          state.currentTool = null;
          this.push(id, "message", truncate(ev.text, 160));
        }
      }

      if (now - state.agentsCheckedAt >= AGENT_SCAN_INTERVAL_MS) {
        state.agentsCheckedAt = now;
        const { active, newest } = this.scanAgents(state);
        if (newest) state.lastAgentActivityAt = Math.max(state.lastAgentActivityAt ?? 0, newest);
        if (active !== state.activeAgents) {
          state.activeAgents = active;
          changed = true;
        }
      }
    }

    // 経過時間だけで working -> idle に落ちる分も配信したいので、変化が無くても定期的に流す。
    if (changed) this.emitUpdate();
    else if (this.listenerCount("tick") > 0) this.emit("tick", this.snapshot());
  }

  /** 稼働中のサブエージェント数と、サブエージェント側の最終更新時刻を返す。 */
  private scanAgents(state: SessionState): { active: number; newest: number } {
    if (!state.transcriptPath) return { active: 0, newest: 0 };
    const dir = subagentDir(state.transcriptPath);
    if (!existsSync(dir)) return { active: 0, newest: 0 };
    const now = Date.now();
    let active = 0;
    let newest = 0;
    try {
      for (const f of readdirSync(dir)) {
        if (!f.endsWith(".jsonl")) continue;
        const mtime = statSync(join(dir, f)).mtimeMs;
        if (now - mtime < AGENT_WINDOW_MS) active++;
        if (mtime > newest) newest = mtime;
      }
    } catch {
      return { active: 0, newest: 0 };
    }
    return { active, newest };
  }

  // ── フック層 ──────────────────────────────────────
  /** Claude Code のフックから届いた状態遷移を反映する。ログには残らない情報はここでしか取れない。 */
  applyHook(payload: HookPayload): boolean {
    const id = payload.session_id;
    if (!id) return false;
    let state = this.sessions.get(id);
    if (!state) {
      // 在庫スキャンより先に hook が来ることがある。取り込んでから拾い直す。
      this.guard(() => this.scanInventory());
      state = this.sessions.get(id);
      if (!state) return false;
    }

    const event = payload.hook_event_name ?? "";
    const now = Date.now();
    let status: SessionStatus | null = null;
    let detail: string | null = null;
    let feed: { kind: FeedKind; text: string } | null = null;

    switch (event) {
      case "UserPromptSubmit":
        status = "working";
        feed = { kind: "status", text: "指示を受け取りました" };
        break;
      case "Stop":
        status = "idle";
        feed = { kind: "status", text: "応答完了" };
        break;
      case "Notification": {
        const type = payload.notification_type ?? "";
        if (type === "permission_prompt") {
          status = "permission";
          detail = payload.tool_name ?? payload.notification_message ?? null;
          feed = { kind: "status", text: `権限の確認待ち${detail ? `: ${detail}` : ""}` };
        } else if (type === "idle_prompt" || type === "agent_needs_input") {
          status = "waiting";
          detail = payload.notification_message ?? null;
          feed = { kind: "status", text: "入力待ちで停止中" };
        } else {
          // 未知の種別を握り潰すと、フック層が効いていないことに気づけない。
          feed = { kind: "status", text: `通知: ${type || "(種別なし)"}` };
        }
        break;
      }
      case "StopFailure":
        status = "error";
        detail = payload.error_type ?? payload.error_message ?? null;
        feed = { kind: "status", text: `停止: ${detail ?? "APIエラー"}` };
        break;
      case "SubagentStart":
        feed = { kind: "agent", text: `サブエージェント開始: ${payload.agent_type ?? "?"}` };
        break;
      case "SubagentStop":
        feed = { kind: "agent", text: `サブエージェント完了: ${payload.agent_type ?? "?"}` };
        break;
      case "PreToolUse":
        status = "working";
        state.currentTool = payload.tool_name ?? state.currentTool;
        break;
    }

    if (status) {
      state.hookStatus = status;
      state.hookDetail = detail;
      state.hookAt = now;
      if (status === "working") state.lastActivityAt = now;
    }
    if (feed) this.push(id, feed.kind, feed.text);
    this.emitUpdate();
    return true;
  }

  // ── 配信 ──────────────────────────────────────────
  private push(sessionId: string, kind: FeedKind, text: string, tool: string | null = null): void {
    const state = this.sessions.get(sessionId);
    const item: FeedItem = {
      id: ++this.feedSeq,
      sessionId,
      project: state ? basename(state.raw.cwd) : "?",
      at: Date.now(),
      kind,
      text,
      tool,
    };
    this.feed.push(item);
    if (this.feed.length > FEED_LIMIT) this.feed = this.feed.slice(-FEED_LIMIT);
    this.emit("feed", item);
  }

  private emitUpdate(): void {
    this.emit("sessions", this.snapshot());
  }

  private statusOf(state: SessionState): { status: SessionStatus; source: StatusSource } {
    if (!state.raw.alive) return { status: "stopped", source: "inventory" };

    // Agent 実行中は親ログが無音になるので、サブエージェント側の更新も活動として数える。
    const last = lastActivity(state);
    const since = last === 0 ? Infinity : Date.now() - last;
    // 親が応答を終えていても、裏でサブエージェントが動いていれば作業は進んでいる。
    const busy =
      state.activeAgents > 0 || (state.turnState === "busy" && since < STALE_BUSY_MS);

    // ログ側の活動がフックより新しければ、実際には動いている。
    if (busy && last > state.hookAt) {
      return { status: "working", source: "transcript" };
    }
    if (state.hookStatus) return { status: state.hookStatus, source: "hook" };
    return { status: busy ? "working" : "idle", source: "transcript" };
  }

  snapshot(): SessionSnapshot[] {
    const out: SessionSnapshot[] = [];
    for (const state of this.sessions.values()) {
      const { status, source } = this.statusOf(state);
      out.push({
        sessionId: state.raw.sessionId,
        pid: state.raw.pid,
        alive: state.raw.alive,
        name: state.raw.name ?? basename(state.raw.cwd),
        project: basename(state.raw.cwd),
        cwd: state.raw.cwd,
        branch: state.branch,
        title: state.title,
        lastPrompt: state.lastPrompt,
        status,
        statusSource: source,
        statusDetail: state.hookDetail,
        entrypoint: state.raw.entrypoint ?? null,
        version: state.raw.version ?? null,
        startedAt: state.raw.startedAt,
        lastActivityAt: lastActivity(state) || null,
        currentTool: status === "working" ? state.currentTool : null,
        recentTools: state.recentTools,
        tokens: state.tokens,
        activeAgents: state.activeAgents,
      });
    }
    return out.sort((a, b) => rank(a) - rank(b) || a.project.localeCompare(b.project));
  }

  recentFeed(limit = 80): FeedItem[] {
    return this.feed.slice(-limit);
  }
}

/** 目を引かせたい状態ほど上に出す。 */
function rank(s: SessionSnapshot): number {
  const order: Record<SessionStatus, number> = {
    permission: 0,
    waiting: 1,
    error: 2,
    working: 3,
    idle: 4,
    stopped: 5,
  };
  return order[s.status];
}

/** 親ログとサブエージェントのうち新しい方。無ければ 0。 */
function lastActivity(state: SessionState): number {
  return Math.max(state.lastActivityAt ?? 0, state.lastAgentActivityAt ?? 0);
}

function truncate(text: string, max: number): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > max ? flat.slice(0, max) + "…" : flat;
}
