// 会話履歴 API: 1 セッションの jsonl を最初から読み、チャット表示の単位（発話・応答・ツール）に整形する。
//   GET /api/sessions/:sessionId/transcript[?after=<id>]
//   SSE /events?transcripts=<id>[,<id>...]|*  → `transcript` イベントで追記分を配る
import { closeSync, openSync, readSync, statSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";
import type { Hono } from "hono";
import { resolveTranscript } from "./paths.js";
import { isInjected } from "./transcript.js";
import type { TranscriptEvent, TranscriptItem, TranscriptResponse, TranscriptTool } from "./types.js";

/** 1 回に読む量。数十 MB のログでも巨大なバッファを一度に確保しない。 */
const CHUNK_BYTES = 4 * 1024 * 1024;
const POLL_INTERVAL_MS = 250;
/** 手元に保持するログの上限。購読中のものは数に関わらず残す。 */
const MAX_LOGS = 32;
/** ツールの要約 1 項目の上限。コマンドやパターンは長くなりうる。 */
const MAX_SUMMARY_CHARS = 300;

/** パスに埋め込むので、UUID 相当の文字だけを通す（`..` や `/` を入れさせない）。 */
export function isValidSessionId(id: string): boolean {
  return /^[A-Za-z0-9-]{1,128}$/.test(id);
}

/** tool がどの発話にぶら下がるかを行をまたいで覚えておく。 */
export interface ParseContext {
  parentId: string | null;
}

function clip(text: string, max = MAX_SUMMARY_CHARS): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

/** 対象として一番わかりやすいものを 1 つだけ選ぶ。 */
export function summarizeTool(name: string, input: unknown): TranscriptTool {
  const o = input && typeof input === "object" ? (input as Record<string, unknown>) : {};
  const command = str(o.command);
  const target =
    str(o.file_path) ??
    str(o.notebook_path) ??
    (command ? command.split("\n")[0]! : null) ??
    (str(o.pattern) && str(o.path) ? `${str(o.pattern)} (${str(o.path)})` : str(o.pattern)) ??
    str(o.url) ??
    str(o.query) ??
    str(o.skill) ??
    str(o.subagent_type) ??
    str(o.path);
  const description = str(o.description);
  return {
    name,
    description: description ? clip(description) : null,
    target: target ? clip(target) : null,
  };
}

/** ユーザー行の本文。スラッシュコマンドは打った形（`/name args`）に戻す。 */
function promptText(content: unknown): string | null {
  let text: string;
  if (typeof content === "string") text = content;
  else if (Array.isArray(content)) {
    text = content
      .map((c: any) =>
        c?.type === "text" && typeof c.text === "string" ? c.text : c?.type === "image" ? "[画像]" : "",
      )
      .filter(Boolean)
      .join("\n");
  } else return null;

  const command = /<command-name>([\s\S]*?)<\/command-name>/.exec(text)?.[1]?.trim();
  if (command) {
    const args = /<command-args>([\s\S]*?)<\/command-args>/.exec(text)?.[1]?.trim();
    text = args ? `${command} ${args}` : command;
  }
  return text.trim() || null;
}

/** jsonl の 1 行（パース済み）をチャットの要素に変換する。対象外の行は空配列。 */
export function itemsFromLine(o: any, lineKey: string, ctx: ParseContext): TranscriptItem[] {
  if (!o || typeof o !== "object" || !o.message || typeof o.message !== "object") return [];
  // サブエージェントや要約は親の会話としては見せない。
  if (o.isSidechain === true || o.isMeta === true || o.isCompactSummary === true) return [];
  const base = typeof o.uuid === "string" && o.uuid ? o.uuid : lineKey;
  const at = typeof o.timestamp === "string" ? Date.parse(o.timestamp) || null : null;
  const content = o.message.content;

  if (o.type === "user") {
    const isResult =
      Array.isArray(content) && content.some((c: any) => c && typeof c === "object" && c.type === "tool_result");
    if (isResult || isInjected(content)) return [];
    const text = promptText(content);
    if (!text) return [];
    const id = `${base}:0`;
    ctx.parentId = id;
    return [{ id, kind: "user", at, text, tool: null, parentId: null }];
  }

  if (o.type !== "assistant" || !Array.isArray(content)) return [];
  const out: TranscriptItem[] = [];
  content.forEach((c: any, i: number) => {
    if (!c || typeof c !== "object") return;
    const id = `${base}:${i}`;
    if (c.type === "text" && typeof c.text === "string" && c.text.trim()) {
      out.push({ id, kind: "assistant", at, text: c.text.trim(), tool: null, parentId: null });
      ctx.parentId = id;
    } else if (c.type === "tool_use" && typeof c.name === "string") {
      out.push({
        id,
        kind: "tool",
        at,
        text: null,
        tool: summarizeTool(c.name, c.input),
        parentId: ctx.parentId,
      });
    }
  });
  return out;
}

/** 1 セッション分のログを先頭から読み、以降は追記分だけを読む。 */
export class TranscriptLog {
  items: TranscriptItem[] = [];
  private index = new Map<string, number>();
  private offset = 0;
  private carry = "";
  private lineNo = 0;
  private ctx: ParseContext = { parentId: null };
  // 読み取り境界に跨がったマルチバイト文字を持ち越す。
  private decoder = new StringDecoder("utf8");

  constructor(readonly path: string) {}

  private reset(): void {
    this.items = [];
    this.index.clear();
    this.offset = 0;
    this.carry = "";
    this.lineNo = 0;
    this.ctx = { parentId: null };
    this.decoder = new StringDecoder("utf8");
  }

  /** 追記分を読み、新しく増えた要素だけを返す。 */
  read(): TranscriptItem[] {
    let size: number;
    try {
      size = statSync(this.path).size;
    } catch {
      return [];
    }
    if (size < this.offset) this.reset(); // 切り詰められたら読み直す
    if (size === this.offset) return [];

    let fd: number;
    try {
      fd = openSync(this.path, "r");
    } catch {
      return [];
    }
    const fresh: TranscriptItem[] = [];
    try {
      const buf = Buffer.allocUnsafe(Math.min(CHUNK_BYTES, size - this.offset));
      while (this.offset < size) {
        const n = readSync(fd, buf, 0, Math.min(buf.length, size - this.offset), this.offset);
        if (n <= 0) break;
        this.offset += n;
        const lines = (this.carry + this.decoder.write(buf.subarray(0, n))).split("\n");
        this.carry = lines.pop() ?? ""; // 書き込み途中の行は次回に回す
        for (const line of lines) this.parseLine(line, fresh);
      }
    } catch {
      // 読めた分までは返す。
    } finally {
      closeSync(fd);
    }
    return fresh;
  }

  private parseLine(line: string, into: TranscriptItem[]): void {
    const key = `line${++this.lineNo}`;
    // 対象の行だけ JSON.parse する（ログの大半は添付や履歴スナップショット）。
    if (!line.includes('"user"') && !line.includes('"assistant"')) return;
    let o: unknown;
    try {
      o = JSON.parse(line);
    } catch {
      return;
    }
    for (const item of itemsFromLine(o, key, this.ctx)) {
      if (this.index.has(item.id)) continue;
      this.index.set(item.id, this.items.length);
      this.items.push(item);
      into.push(item);
    }
  }

  /** `after` より後の要素。知らない id なら全件を返して reset を立てる。 */
  since(after: string | undefined): { items: TranscriptItem[]; reset: boolean } {
    if (!after) return { items: this.items, reset: false };
    const at = this.index.get(after);
    if (at === undefined) return { items: this.items, reset: true };
    return { items: this.items.slice(at + 1), reset: false };
  }
}

interface Subscriber {
  /** null は全セッション。 */
  ids: Set<string> | null;
  fn: (ev: TranscriptEvent) => void;
}

/** 購読の指定（`*` か、カンマ区切りの sessionId）を読む。不正な id は捨てる。 */
export function parseSubscription(spec: string | undefined): Set<string> | null | undefined {
  if (spec === undefined || spec.trim() === "") return undefined;
  if (spec.trim() === "*") return null;
  const ids = spec.split(",").map((s) => s.trim()).filter(isValidSessionId);
  return ids.length ? new Set(ids) : undefined;
}

export interface KnownSession {
  sessionId: string;
  cwd: string;
}

/** ログの読み出しと購読者への配信をまとめて持つ。 */
export class TranscriptStore {
  private logs = new Map<string, TranscriptLog>();
  private subscribers = new Set<Subscriber>();
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly known: () => KnownSession[],
    private readonly resolve: (sessionId: string, cwd: string) => string | null = resolveTranscript,
  ) {}

  private logFor(sessionId: string): TranscriptLog | null {
    const existing = this.logs.get(sessionId);
    if (existing) {
      // 最近使ったものを後ろへ回して、追い出し順を LRU にする。
      this.logs.delete(sessionId);
      this.logs.set(sessionId, existing);
      return existing;
    }
    const cwd = this.known().find((s) => s.sessionId === sessionId)?.cwd ?? "";
    const path = this.resolve(sessionId, cwd);
    if (!path) return null;
    const log = new TranscriptLog(path);
    this.logs.set(sessionId, log);
    this.evict();
    return log;
  }

  private evict(): void {
    const watched = this.watchedIds();
    for (const id of this.logs.keys()) {
      if (this.logs.size <= MAX_LOGS) break;
      if (!watched.has(id)) this.logs.delete(id);
    }
  }

  /** 追記を読み、増えた分を購読者へ配る。GET 経由で読んだ分も SSE 側に取りこぼさせない。 */
  private refresh(sessionId: string): TranscriptLog | null {
    const log = this.logFor(sessionId);
    if (!log) return null;
    const fresh = log.read();
    if (fresh.length) {
      const ev: TranscriptEvent = { sessionId, items: fresh };
      for (const sub of this.subscribers) {
        if (sub.ids === null || sub.ids.has(sessionId)) sub.fn(ev);
      }
    }
    return log;
  }

  /** 履歴を返す。ログが見つからなければ null。 */
  get(sessionId: string, after?: string): TranscriptResponse | null {
    if (!isValidSessionId(sessionId)) return null;
    const log = this.refresh(sessionId);
    if (!log) return null;
    return { sessionId, ...log.since(after) };
  }

  private watchedIds(): Set<string> {
    const ids = new Set<string>();
    let all = false;
    for (const sub of this.subscribers) {
      if (sub.ids === null) all = true;
      else for (const id of sub.ids) ids.add(id);
    }
    if (all) for (const s of this.known()) ids.add(s.sessionId);
    return ids;
  }

  /** 追記の購読。登録時点までの内容は既読として扱い、以降の追記だけを届ける。 */
  subscribe(spec: string | undefined, fn: (ev: TranscriptEvent) => void): () => void {
    const ids = parseSubscription(spec);
    if (ids === undefined) return () => {};
    // 既読の基準線を先に引く。登録後に読むと過去の全件が「追記」として届いてしまう。
    for (const id of ids ?? this.known().map((s) => s.sessionId)) this.refresh(id);
    const sub: Subscriber = { ids, fn };
    this.subscribers.add(sub);
    this.startPolling();
    return () => {
      this.subscribers.delete(sub);
      if (this.subscribers.size === 0) this.stop();
    };
  }

  /** 購読されているセッションの追記を読む。 */
  poll(): void {
    for (const id of this.watchedIds()) this.refresh(id);
  }

  private startPolling(): void {
    if (this.timer) return;
    this.timer = setInterval(() => {
      try {
        this.poll();
      } catch (err) {
        console.error("[monitor] transcript poll error:", err);
      }
    }, POLL_INTERVAL_MS);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }
}

/** 履歴 API を登録する。Host / Origin / トークンの検証は server.ts の全体ミドルウェアが先に掛かる。 */
export function registerTranscriptRoutes(app: Hono<any>, store: TranscriptStore): void {
  app.get("/api/sessions/:sessionId/transcript", (c) => {
    c.header("cache-control", "no-store");
    const sessionId = c.req.param("sessionId");
    if (!isValidSessionId(sessionId)) return c.json({ ok: false, error: "invalid session id" }, 400);
    const result = store.get(sessionId, c.req.query("after") || undefined);
    if (!result) return c.json({ ok: false, error: "transcript not found" }, 404);
    return c.json(result);
  });
}
