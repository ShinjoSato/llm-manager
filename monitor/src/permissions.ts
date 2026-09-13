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
/** 判断が出た後の取り置き。取り直しの谷間（待ち手が居ない瞬間）に押された分を渡すため。 */
export const DECIDED_TTL_MS = 120_000;
/** 暴走したチャネルで画面が埋まらないための上限。超えたら古いものから捨てる。 */
export const MAX_PENDING = 50;

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

/**
 * 保留の鍵。request_id はセッション内でしか一意でないので、申請元の PID と対で持つ
 * （別セッションの同じ ID に判断が配られるのを防ぐ）。
 */
export function pendingKey(input: Pick<PermissionRequestInput, "pid" | "requestId">): string {
  return `${input.pid ?? "x"}-${input.requestId}`;
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
 * cwd では引かない（同じ場所の別セッションに付け替わると、見ていない確認を許可させる）。
 */
export function matchSession(
  input: Pick<PermissionRequestInput, "pid">,
  sessions: Iterable<SessionRef>,
): string | null {
  if (input.pid === null) return null;
  for (const s of sessions) {
    if (s.alive && s.pid === input.pid) return s.sessionId;
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
interface Decided {
  decision: PermissionDecision;
  at: number;
  toolName: string;
  inputPreview: string;
}

export class PermissionRegistry {
  private entries = new Map<string, Entry>();
  private decided = new Map<string, Decided>();

  /**
   * すでに判断が出ている申請なら、それを渡して忘れる。無ければ null。
   * 同じ鍵でも中身が違えば別の確認なので渡さない（無確認で通してしまわないため）。
   */
  takeDecision(
    key: string,
    input: Pick<PermissionRequestInput, "toolName" | "inputPreview">,
    now = Date.now(),
  ): PermissionDecision | null {
    const hit = this.decided.get(key);
    if (!hit) return null;
    this.decided.delete(key);
    if (hit.toolName !== input.toolName || hit.inputPreview !== input.inputPreview) return null;
    return now - hit.at < DECIDED_TTL_MS ? hit.decision : null;
  }

  /** 申請を預かる（同じ鍵の取り直しなら生存を延ばすだけ）。 */
  register(
    input: PermissionRequestInput,
    link: { sessionId: string | null; project: string | null },
    now = Date.now(),
  ): {
    pending: PendingPermission;
    created: boolean;
    changed: boolean;
    /** 今回はじめてセッションに紐付いた。 */
    linked: boolean;
    /** 上限を超えて捨てた分。 */
    evicted: PendingPermission[];
  } {
    const key = pendingKey(input);
    const existing = this.entries.get(key);
    if (existing) {
      existing.seenAt = now;
      // セッションは後から在庫に載ることがあるので、引けた分だけ上書きする。
      const sessionId = link.sessionId ?? existing.pending.sessionId;
      const project = link.project ?? existing.pending.project;
      const linked = !existing.pending.sessionId && !!sessionId;
      let changed =
        sessionId !== existing.pending.sessionId || project !== existing.pending.project;
      existing.pending.sessionId = sessionId;
      existing.pending.project = project;
      // 鍵が同じでも中身が違えば別の確認。古い表示のまま答えさせない。
      if (
        existing.pending.toolName !== input.toolName ||
        existing.pending.inputPreview !== input.inputPreview
      ) {
        existing.pending.toolName = input.toolName;
        existing.pending.description = input.description;
        existing.pending.inputPreview = input.inputPreview;
        existing.pending.askedAt = now;
        changed = true;
      }
      return { pending: existing.pending, created: false, changed, linked, evicted: [] };
    }
    const pending: PendingPermission = {
      key,
      requestId: input.requestId,
      sessionId: link.sessionId,
      project: link.project,
      toolName: input.toolName,
      description: input.description,
      inputPreview: input.inputPreview,
      askedAt: now,
    };
    this.entries.set(key, { pending, seenAt: now, waiters: [] });
    return {
      pending,
      created: true,
      changed: true,
      linked: !!link.sessionId,
      evicted: this.evictOverflow(),
    };
  }

  /** 上限を超えた分を古い順に捨てる。 */
  private evictOverflow(): PendingPermission[] {
    if (this.entries.size <= MAX_PENDING) return [];
    const oldest = [...this.entries.entries()].sort(
      (a, b) => a[1].pending.askedAt - b[1].pending.askedAt,
    );
    const evicted: PendingPermission[] = [];
    for (const [key, entry] of oldest.slice(0, this.entries.size - MAX_PENDING)) {
      this.entries.delete(key);
      for (const waiter of entry.waiters) waiter("dropped");
      evicted.push(entry.pending);
    }
    return evicted;
  }

  /** 判断が出るまで待つ。出なければ timeout を返してチャネルに取り直させる。 */
  wait(key: string, timeoutMs: number): Promise<PermissionOutcome> {
    const entry = this.entries.get(key);
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

  /** 画面からの判断。知らない鍵なら null（＝404）。 */
  decide(key: string, decision: PermissionDecision, now = Date.now()): PendingPermission | null {
    const entry = this.entries.get(key);
    if (!entry) return null;
    this.entries.delete(key);
    // 待ち手が居ない時だけ取り置く。配れた分まで残すと、次に来た別の確認に適用されかねない。
    if (entry.waiters.length === 0) {
      const { toolName, inputPreview } = entry.pending;
      this.decided.set(key, { decision, at: now, toolName, inputPreview });
    }
    for (const waiter of entry.waiters) waiter(decision);
    return entry.pending;
  }

  /**
   * 端末側で先に答えられた分を落とす。申請を預かった後に書かれたログ行があれば、
   * そのセッションの確認はもう終わっている（Claude Code は取り消しを知らせてこない）。
   */
  dropResolved(sessionId: string, lastActivityAt: number): PendingPermission[] {
    const dropped: PendingPermission[] = [];
    for (const [key, entry] of this.entries) {
      if (entry.pending.sessionId !== sessionId) continue;
      if (lastActivityAt <= entry.pending.askedAt) continue;
      this.entries.delete(key);
      for (const waiter of entry.waiters) waiter("dropped");
      dropped.push(entry.pending);
    }
    return dropped;
  }

  /** 取りに来なくなった分と、古すぎる分を捨てる。 */
  sweep(now = Date.now()): PendingPermission[] {
    const dropped: PendingPermission[] = [];
    for (const [key, entry] of this.entries) {
      if (now - entry.seenAt < PENDING_TTL_MS && now - entry.pending.askedAt < PENDING_MAX_AGE_MS) {
        continue;
      }
      this.entries.delete(key);
      for (const waiter of entry.waiters) waiter("dropped");
      dropped.push(entry.pending);
    }
    for (const [key, hit] of this.decided) {
      if (now - hit.at >= DECIDED_TTL_MS) this.decided.delete(key);
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
