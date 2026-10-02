// 会話履歴 API: 1 セッションの jsonl を最初から読み、チャット表示の単位（発話・応答・ツール）に整形する。
//   GET /api/sessions/:sessionId/transcript[?after=<id>]
//   GET /api/sessions/:sessionId/transcript/:itemId/images/:index  → 発話に添えられた画像の本体（バイナリ）
//   SSE /events?transcripts=<id>[,<id>...]|*  → `transcript` イベントで追記分を配る
import { closeSync, openSync, readSync, statSync } from "node:fs";
import { type FileHandle, open } from "node:fs/promises";
import type { Hono } from "hono";
import { resolveTranscript } from "./paths.js";
import { isInjected } from "./transcript.js";
import type { TranscriptEvent, TranscriptImage, TranscriptItem, TranscriptResponse, TranscriptTool } from "./types.js";

/** 1 回に読む量。数十 MB のログでも巨大なバッファを一度に確保しない。 */
const CHUNK_BYTES = 4 * 1024 * 1024;
const POLL_INTERVAL_MS = 250;
/** 手元に保持するログの上限。購読中のものは数に関わらず残す。 */
const MAX_LOGS = 32;
/** ツールの要約 1 項目の上限。コマンドやパターンは長くなりうる。 */
const MAX_SUMMARY_CHARS = 300;

/** 画像の取り出しで 1 行として読む上限。壊れた位置情報で巨大な読み込みをしない。 */
const MAX_IMAGE_LINE_BYTES = 64 * 1024 * 1024;
/** 解析済みの画像を持っておく行数と合計の上限。サムネイルが並んでも同じ行を読み直さない程度に小さく持つ。 */
const MAX_DECODED_LINES = 4;
const MAX_DECODED_BYTES = 32 * 1024 * 1024;
/** 返してよい画像の形式。SVG 等の文書型はブラウザで開かれた時にスクリプトが動きうるので通さない。 */
export const IMAGE_MEDIA_TYPES: ReadonlySet<string> = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/** パスに埋め込むので、UUID 相当の文字だけを通す（`..` や `/` を入れさせない）。 */
export function isValidSessionId(id: string): boolean {
  return /^[A-Za-z0-9-]{1,128}$/.test(id);
}

/** 履歴の要素 id（`<uuid>:<ブロック番号>` / `line<N>:<ブロック番号>`）。 */
export function isValidItemId(id: string): boolean {
  return /^[A-Za-z0-9-]{1,128}:\d{1,6}$/.test(id);
}

/** content の画像ブロックを順に返す（`index` は形式を問わず数えた位置）。 */
function imageBlocks(content: unknown): { index: number; block: any }[] {
  if (!Array.isArray(content)) return [];
  const out: { index: number; block: any }[] = [];
  for (const c of content) if (c && typeof c === "object" && (c as any).type === "image") out.push({ index: out.length, block: c });
  return out;
}

function isServableImage(block: any): boolean {
  const source = block?.source;
  return (
    !!source &&
    source.type === "base64" &&
    typeof source.data === "string" &&
    typeof source.media_type === "string" &&
    IMAGE_MEDIA_TYPES.has(source.media_type)
  );
}

/** 発話に添えられた画像の目録。取り出せる形式（base64 の PNG / JPEG / GIF / WebP）だけを載せる。 */
export function imagesOf(content: unknown): TranscriptImage[] {
  return imageBlocks(content)
    .filter(({ block }) => isServableImage(block))
    .map(({ index, block }) => ({ index, mediaType: block.source.media_type as string }));
}

/** `index` 枚目の画像の本体。取り出せない形式・範囲外なら null。 */
export function imageDataOf(content: unknown, index: number): { mediaType: string; data: Buffer } | null {
  const found = imageBlocks(content).find((b) => b.index === index);
  if (!found || !isServableImage(found.block)) return null;
  const data = Buffer.from(found.block.source.data as string, "base64");
  return data.length ? { mediaType: found.block.source.media_type as string, data } : null;
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
    return [{ id, kind: "user", at, text, tool: null, parentId: null, images: imagesOf(content) }];
  }

  if (o.type !== "assistant" || !Array.isArray(content)) return [];
  const out: TranscriptItem[] = [];
  content.forEach((c: any, i: number) => {
    if (!c || typeof c !== "object") return;
    const id = `${base}:${i}`;
    if (c.type === "text" && typeof c.text === "string" && c.text.trim()) {
      out.push({ id, kind: "assistant", at, text: c.text.trim(), tool: null, parentId: null, images: [] });
      ctx.parentId = id;
    } else if (c.type === "tool_use" && typeof c.name === "string") {
      out.push({
        id,
        kind: "tool",
        at,
        text: null,
        tool: summarizeTool(c.name, c.input),
        parentId: ctx.parentId,
        images: [],
      });
    }
  });
  return out;
}

/** 画像付きの行の位置。`length` はバイト数。 */
interface ImageLineRef {
  offset: number;
  length: number;
  uuid: string | null;
}

/** 1 行から取り出した画像（目録の位置ごと。取り出せないものは null）。 */
interface DecodedImages {
  images: ({ mediaType: string; data: Buffer } | null)[];
  bytes: number;
}

/** 読み直した行が画像付きの発話か。uuid が分かっていれば一致も見る。 */
function isImageLine(o: any, uuid: string | null): boolean {
  if (!o || typeof o !== "object" || o.type !== "user") return false;
  if (uuid !== null && o.uuid !== uuid) return false;
  return imagesOf(o.message?.content).length > 0;
}

function decodeImages(o: any): DecodedImages {
  const content = o?.message?.content;
  const images = imageBlocks(content).map(({ index }) => imageDataOf(content, index));
  return { images, bytes: images.reduce((sum, img) => sum + (img?.data.length ?? 0), 0) };
}

/** 1 セッション分のログを先頭から読み、以降は追記分だけを読む。 */
export class TranscriptLog {
  items: TranscriptItem[] = [];
  private index = new Map<string, number>();
  private offset = 0;
  /** 書きかけの行の断片。位置をバイトで数えるため、文字列にせずに持ち越す。 */
  private carry: Buffer[] = [];
  private lineNo = 0;
  /** 持ち越し中の行がファイルの何バイト目から始まるか。 */
  private lineStart = 0;
  /** 画像付きの発話 id → その行の位置。画像の本体は手元に持たず、求められた時に読み直す。 */
  private imageLines = new Map<string, ImageLineRef>();
  /** 直近に解析した画像付きの行（LRU）。同じ発話の複数枚を 1 回の読み込みで返す。 */
  private decoded = new Map<string, DecodedImages>();
  private decodedBytes = 0;
  private pending = new Map<string, Promise<DecodedImages | null>>();
  /** 画像のために行を読み直した回数（試験用）。 */
  lineReads = 0;
  private ctx: ParseContext = { parentId: null };

  constructor(readonly path: string) {}

  private reset(): void {
    this.items = [];
    this.index.clear();
    this.imageLines.clear();
    this.decoded.clear();
    this.decodedBytes = 0;
    this.pending.clear();
    this.offset = 0;
    this.lineStart = 0;
    this.carry = [];
    this.lineNo = 0;
    this.ctx = { parentId: null };
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
        let start = 0;
        for (let nl = buf.indexOf(10, 0); nl !== -1 && nl < n; nl = buf.indexOf(10, start)) {
          const tail = buf.subarray(start, nl);
          const bytes = this.carry.length ? Buffer.concat([...this.carry, tail]) : tail;
          this.carry = [];
          this.parseLine(bytes.toString("utf8"), fresh, this.lineStart, bytes.length);
          this.lineStart += bytes.length + 1;
          start = nl + 1;
        }
        // 書き込み途中の行は次回に回す（buf は使い回すので複製して持つ）。
        if (start < n) this.carry.push(Buffer.from(buf.subarray(start, n)));
      }
    } catch {
      // 読めた分までは返す。
    } finally {
      closeSync(fd);
    }
    return fresh;
  }

  private parseLine(line: string, into: TranscriptItem[], offset: number, length: number): void {
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
      if (item.images.length) {
        const uuid = typeof (o as any).uuid === "string" ? ((o as any).uuid as string) : null;
        this.imageLines.set(item.id, { offset, length, uuid });
      }
    }
  }

  /** 発話 `itemId` の `index` 枚目の画像。行を読み直して取り出す。見つからなければ null。 */
  async image(itemId: string, index: number): Promise<{ mediaType: string; data: Buffer } | null> {
    const decoded = await this.decodedFor(itemId);
    return decoded?.images[index] ?? null;
  }

  private decodedFor(itemId: string): Promise<DecodedImages | null> {
    const hit = this.decoded.get(itemId);
    if (hit) {
      this.decoded.delete(itemId);
      this.decoded.set(itemId, hit);
      return Promise.resolve(hit);
    }
    // 同じ発話の画像が並んで求められても、読み込みと解析は 1 回にまとめる。
    const inflight = this.pending.get(itemId);
    if (inflight) return inflight;
    const job = this.load(itemId).finally(() => {
      if (this.pending.get(itemId) === job) this.pending.delete(itemId);
    });
    this.pending.set(itemId, job);
    return job;
  }

  private async load(itemId: string): Promise<DecodedImages | null> {
    const ref = this.imageLines.get(itemId);
    if (!ref) return null;
    this.lineReads++;
    let o = await this.lineAt(ref.offset, ref.length);
    if (!isImageLine(o, ref.uuid)) {
      // 位置が合わなければ uuid で探し直し、見つけた位置を覚え直す。uuid が無い行は取り違えを避けて諦める。
      const found = ref.uuid ? await this.findLine(ref.uuid) : null;
      if (!found) return null;
      if (this.imageLines.get(itemId) === ref) {
        this.imageLines.set(itemId, { offset: found.offset, length: found.length, uuid: ref.uuid });
      }
      o = found.o;
    }
    const decoded = decodeImages(o);
    // 読んでいる間に読み直し（reset）が入ったら、古い内容を残さない。
    if (this.imageLines.has(itemId)) this.remember(itemId, decoded);
    return decoded;
  }

  private remember(itemId: string, decoded: DecodedImages): void {
    if (decoded.bytes > MAX_DECODED_BYTES || this.decoded.has(itemId)) return;
    this.decoded.set(itemId, decoded);
    this.decodedBytes += decoded.bytes;
    for (const [id, old] of this.decoded) {
      if (this.decoded.size <= MAX_DECODED_LINES && this.decodedBytes <= MAX_DECODED_BYTES) break;
      this.decoded.delete(id);
      this.decodedBytes -= old.bytes;
    }
  }

  private async lineAt(offset: number, length: number): Promise<any> {
    if (length <= 0 || length > MAX_IMAGE_LINE_BYTES) return null;
    let file: FileHandle;
    try {
      file = await open(this.path, "r");
    } catch {
      return null;
    }
    try {
      const buf = Buffer.allocUnsafe(length);
      const { bytesRead } = await file.read(buf, 0, length, offset);
      return JSON.parse(buf.subarray(0, bytesRead).toString("utf8"));
    } catch {
      return null;
    } finally {
      await file.close().catch(() => {});
    }
  }

  /** uuid の行をバイト位置付きで探す。チャンクごとに読み込みを待つので、走査中もイベントループを止めない。 */
  private async findLine(uuid: string): Promise<{ o: any; offset: number; length: number } | null> {
    let file: FileHandle;
    try {
      file = await open(this.path, "r");
    } catch {
      return null;
    }
    const needle = Buffer.from(`"uuid":"${uuid}"`);
    let parts: Buffer[] = [];
    let partBytes = 0;
    let skip = false; // 上限を超えた行は末尾まで読み飛ばす
    let lineStart = 0;
    let position = 0;
    try {
      const buf = Buffer.allocUnsafe(CHUNK_BYTES);
      for (;;) {
        const { bytesRead: n } = await file.read(buf, 0, buf.length, position);
        if (n <= 0) break;
        let start = 0;
        for (let nl = buf.indexOf(10, 0); nl !== -1 && nl < n; nl = buf.indexOf(10, start)) {
          const length = partBytes + (nl - start);
          if (!skip) {
            const tail = buf.subarray(start, nl);
            const bytes = parts.length ? Buffer.concat([...parts, tail]) : tail;
            if (bytes.includes(needle)) {
              try {
                const o = JSON.parse(bytes.toString("utf8"));
                if (isImageLine(o, uuid)) return { o, offset: lineStart, length };
              } catch {
                // 壊れた行は飛ばす。
              }
            }
          }
          parts = [];
          partBytes = 0;
          skip = false;
          lineStart = position + nl + 1;
          start = nl + 1;
        }
        if (start < n) {
          partBytes += n - start;
          if (partBytes > MAX_IMAGE_LINE_BYTES) {
            skip = true;
            parts = [];
          } else if (!skip) parts.push(Buffer.from(buf.subarray(start, n)));
        }
        position += n;
      }
    } catch {
      return null;
    } finally {
      await file.close().catch(() => {});
    }
    return null;
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

  /** 発話に添えられた画像の本体。履歴・発話・画像が見つからなければ null。 */
  async image(sessionId: string, itemId: string, index: number): Promise<{ mediaType: string; data: Buffer } | null> {
    if (!isValidSessionId(sessionId) || !isValidItemId(itemId) || !Number.isInteger(index) || index < 0) return null;
    return (await this.refresh(sessionId)?.image(itemId, index)) ?? null;
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

  app.get("/api/sessions/:sessionId/transcript/:itemId/images/:index", async (c) => {
    const sessionId = c.req.param("sessionId");
    const itemId = c.req.param("itemId");
    const index = c.req.param("index");
    if (!isValidSessionId(sessionId) || !isValidItemId(itemId) || !/^\d{1,4}$/.test(index)) {
      c.header("cache-control", "no-store");
      return c.json({ ok: false, error: "invalid image path" }, 400);
    }
    const image = await store.image(sessionId, itemId, Number(index));
    if (!image) {
      c.header("cache-control", "no-store");
      return c.json({ ok: false, error: "image not found" }, 404);
    }
    return c.body(new Uint8Array(image.data), 200, {
      "content-type": image.mediaType,
      // uuid の発話は中身が変わらないので受け手に持たせる（共有キャッシュには置かせない）。行番号の id は読み直しでずれうるので持たせない。
      "cache-control": /^line\d+:/.test(itemId) ? "no-store" : "private, max-age=86400",
      "x-content-type-options": "nosniff",
      "content-security-policy": "default-src 'none'",
    });
  });
}
