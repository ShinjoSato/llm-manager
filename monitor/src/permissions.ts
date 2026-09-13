// 権限確認の中継。チャネル（src/channel.ts）が申請を預け、判断が決まるまで長ポーリングで待つ。
import { isLoopbackAddress } from "./origin.js";
import type { PendingPermission } from "./types.js";

export const DECISIONS = ["allow", "deny"] as const;
export type PermissionDecision = (typeof DECISIONS)[number];

/** 待ち受けの終わり方。timeout はチャネルが取り直す、dropped は諦める合図。 */
export type PermissionOutcome = PermissionDecision | "timeout" | "dropped";

/** チャネルが取りに来なくなったら保留を消す。長ポーリングの一巡より十分長くする。 */
export const PENDING_TTL_MS = 90_000;
/** 端末側で答えられたことに気づけない場合の保険。ここまで来たら諦めて消す。 */
export const PENDING_MAX_AGE_MS = 30 * 60_000;

/** 表示だけに使う文字列なので、画面と SSE を守れる長さで切る。 */
const MAX_TOOL_NAME = 80;
const MAX_DESCRIPTION = 600;
const MAX_INPUT_PREVIEW = 4_000;
/** Claude Code が出すのは 5 文字だが、形が変わっても通るよう緩めに見る。 */
const REQUEST_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

export function isDecision(value: unknown): value is PermissionDecision {
  return typeof value === "string" && (DECISIONS as readonly string[]).includes(value);
}

/**
 * 承認を受け付けてよい相手か。ループバック以外は常に false。
 * LAN は平文 HTTP なので、トークンを持つ端末にも任意コマンドの承認を許さない
 * （スマホからの承認は `claude --remote-control` が担う）。
 */
export function isLocalActor(remoteAddress: string | undefined): boolean {
  return isLoopbackAddress(remoteAddress);
}

/** チャネルから預かる申請。 */
export interface PermissionRequestInput {
  requestId: string;
  toolName: string;
  description: string;
  inputPreview: string;
  /** チャネルを起動した Claude Code のプロセス ID（チャネルの親）。 */
  pid: number | null;
  cwd: string | null;
}

/** 受け口の本体を検証して読む。形が合わなければ null（＝400）。 */
export function parseRequest(body: unknown): PermissionRequestInput | null {
  if (typeof body !== "object" || body === null) return null;
  const o = body as Record<string, unknown>;
  const requestId = typeof o.requestId === "string" ? o.requestId : "";
  if (!REQUEST_ID_RE.test(requestId)) return null;
  const toolName = typeof o.toolName === "string" ? o.toolName.trim() : "";
  if (!toolName) return null;
  return {
    requestId,
    toolName: clip(toolName, MAX_TOOL_NAME),
    description: clip(typeof o.description === "string" ? o.description : "", MAX_DESCRIPTION),
    inputPreview: clip(typeof o.inputPreview === "string" ? o.inputPreview : "", MAX_INPUT_PREVIEW),
    pid: typeof o.pid === "number" && Number.isInteger(o.pid) && o.pid > 0 ? o.pid : null,
    cwd: typeof o.cwd === "string" && o.cwd ? o.cwd : null,
  };
}

function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

/** セッションを引くのに使う分だけ。 */
export interface SessionRef {
  sessionId: string;
  pid: number;
  cwd: string;
  alive: boolean;
}

/**
 * 申請元のセッション。チャネルは Claude Code の子プロセスなので親 PID で一意に引ける。
 * PID で引けない時だけ cwd を見るが、同じ cwd が複数あれば取り違えるので諦める。
 */
export function matchSession(
  input: Pick<PermissionRequestInput, "pid" | "cwd">,
  sessions: Iterable<SessionRef>,
): string | null {
  const alive = [...sessions].filter((s) => s.alive);
  if (input.pid !== null) {
    const byPid = alive.find((s) => s.pid === input.pid);
    if (byPid) return byPid.sessionId;
  }
  if (input.cwd !== null) {
    const byCwd = alive.filter((s) => s.cwd === input.cwd);
    if (byCwd.length === 1) return byCwd[0]!.sessionId;
  }
  return null;
}

interface Entry {
  pending: PendingPermission;
  /** チャネルが最後に取りに来た時刻。 */
  seenAt: number;
  waiters: ((outcome: PermissionOutcome) => void)[];
}

/** 保留中の権限確認。判断が決まるか、端末側で答えられるまで持つ。 */
export class PermissionRegistry {
  private entries = new Map<string, Entry>();

  /** 申請を預かる（同じ ID の取り直しなら生存を延ばすだけ）。 */
  register(
    input: PermissionRequestInput,
    link: { sessionId: string | null; project: string | null },
    now = Date.now(),
  ): { pending: PendingPermission; created: boolean } {
    const existing = this.entries.get(input.requestId);
    if (existing) {
      existing.seenAt = now;
      // セッションは後から在庫に載ることがあるので、引けた時だけ上書きする。
      if (link.sessionId) {
        existing.pending.sessionId = link.sessionId;
        existing.pending.project = link.project;
      }
      return { pending: existing.pending, created: false };
    }
    const pending: PendingPermission = {
      requestId: input.requestId,
      sessionId: link.sessionId,
      project: link.project,
      toolName: input.toolName,
      description: input.description,
      inputPreview: input.inputPreview,
      askedAt: now,
    };
    this.entries.set(input.requestId, { pending, seenAt: now, waiters: [] });
    return { pending, created: true };
  }

  /** 判断が出るまで待つ。出なければ timeout を返してチャネルに取り直させる。 */
  wait(requestId: string, timeoutMs: number): Promise<PermissionOutcome> {
    const entry = this.entries.get(requestId);
    if (!entry) return Promise.resolve("dropped");
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        entry.waiters = entry.waiters.filter((w) => w !== waiter);
        resolve("timeout");
      }, timeoutMs);
      const waiter = (outcome: PermissionOutcome) => {
        clearTimeout(timer);
        resolve(outcome);
      };
      entry.waiters.push(waiter);
    });
  }

  /** 画面からの判断。知らない ID なら false（＝404）。 */
  decide(requestId: string, decision: PermissionDecision): PendingPermission | null {
    const entry = this.entries.get(requestId);
    if (!entry) return null;
    this.entries.delete(requestId);
    for (const waiter of entry.waiters) waiter(decision);
    return entry.pending;
  }

  /**
   * 端末側で先に答えられた分を落とす。申請を預かった後に書かれたログ行があれば、
   * そのセッションの確認はもう終わっている（Claude Code は取り消しを知らせてこない）。
   */
  dropResolved(sessionId: string, lastActivityAt: number): PendingPermission[] {
    const dropped: PendingPermission[] = [];
    for (const [id, entry] of this.entries) {
      if (entry.pending.sessionId !== sessionId) continue;
      if (lastActivityAt <= entry.pending.askedAt) continue;
      this.entries.delete(id);
      for (const waiter of entry.waiters) waiter("dropped");
      dropped.push(entry.pending);
    }
    return dropped;
  }

  /** 取りに来なくなった分と、古すぎる分を捨てる。 */
  sweep(now = Date.now()): PendingPermission[] {
    const dropped: PendingPermission[] = [];
    for (const [id, entry] of this.entries) {
      if (now - entry.seenAt < PENDING_TTL_MS && now - entry.pending.askedAt < PENDING_MAX_AGE_MS) {
        continue;
      }
      this.entries.delete(id);
      for (const waiter of entry.waiters) waiter("dropped");
      dropped.push(entry.pending);
    }
    return dropped;
  }

  /** 古いものから並べる。先に来た確認ほど上に出す。 */
  list(): PendingPermission[] {
    return [...this.entries.values()]
      .map((e) => ({ ...e.pending }))
      .sort((a, b) => a.askedAt - b.askedAt);
  }

  size(): number {
    return this.entries.size;
  }
}
