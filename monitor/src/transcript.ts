// 実況層: セッションログ(jsonl)の末尾差分を読んで「今なにをしているか」を取り出す。
// ログはツール実行と同時に追記されるが、書かれる単位はターン／ツール呼び出しであってトークン単位ではない。
import { openSync, readSync, closeSync, statSync } from "node:fs";
import { StringDecoder } from "node:string_decoder";
import type { TokenUsage } from "./types.js";

/** 初回に遡って読む量。ログは数MBまで育つので全読みしない。 */
const BOOTSTRAP_BYTES = 512 * 1024;
/** メタ情報スキャンの上限。巨大なログでも初回が止まらないようにする。 */
const MAX_SCAN_BYTES = 32 * 1024 * 1024;

/** ツール呼び出しの中身。キャラの持ち物と一言に使う。 */
export interface ToolDetail {
  name: string;
  skill?: string;
  subagentType?: string;
  description?: string;
}

export interface ParsedEvent {
  type: string;
  at: number | null;
  title?: string;
  lastPrompt?: string;
  branch?: string;
  tools?: string[];
  toolDetail?: ToolDetail;
  /** user 行の中身。tool_result と実際のユーザー入力を区別する。 */
  userKind?: "tool_result" | "prompt";
  text?: string;
  usage?: TokenUsage;
}

function toolDetail(name: string, input: unknown): ToolDetail {
  const detail: ToolDetail = { name };
  if (!input || typeof input !== "object") return detail;
  const o = input as Record<string, unknown>;
  if (typeof o.skill === "string") detail.skill = o.skill;
  if (typeof o.subagent_type === "string") detail.subagentType = o.subagent_type;
  if (typeof o.description === "string") detail.description = o.description;
  return detail;
}

function parseLine(line: string): ParsedEvent | null {
  let o: Record<string, any>;
  try {
    o = JSON.parse(line);
  } catch {
    return null;
  }
  const type = typeof o.type === "string" ? o.type : "unknown";
  const ev: ParsedEvent = {
    type,
    at: typeof o.timestamp === "string" ? Date.parse(o.timestamp) || null : null,
  };
  if (typeof o.gitBranch === "string" && o.gitBranch) ev.branch = o.gitBranch;
  if (type === "ai-title" && typeof o.aiTitle === "string") ev.title = o.aiTitle;
  if (type === "last-prompt" && typeof o.lastPrompt === "string") ev.lastPrompt = o.lastPrompt;

  if (type === "user" && o.message && typeof o.message === "object") {
    const content = o.message.content;
    const isResult =
      Array.isArray(content) &&
      content.some((c: any) => c && typeof c === "object" && c.type === "tool_result");
    ev.userKind = isResult ? "tool_result" : "prompt";
  }

  if (type === "assistant" && o.message && typeof o.message === "object") {
    const content = Array.isArray(o.message.content) ? o.message.content : [];
    const tools: string[] = [];
    let text = "";
    for (const c of content) {
      if (!c || typeof c !== "object") continue;
      if (c.type === "tool_use" && typeof c.name === "string") {
        tools.push(c.name);
        ev.toolDetail = toolDetail(c.name, c.input);
      } else if (c.type === "text" && typeof c.text === "string") text += c.text;
    }
    if (tools.length) ev.tools = tools;
    if (text.trim()) ev.text = text.trim();

    const u = o.message.usage;
    if (u && typeof u === "object") {
      ev.usage = {
        input: Number(u.input_tokens) || 0,
        output: Number(u.output_tokens) || 0,
        cacheRead: Number(u.cache_read_input_tokens) || 0,
      };
    }
  }
  return ev;
}

function readTail(path: string, maxBytes: number): string {
  let size: number;
  try {
    size = statSync(path).size;
  } catch {
    return "";
  }
  const start = Math.max(0, size - maxBytes);
  if (size <= start) return "";
  let fd: number;
  try {
    fd = openSync(path, "r");
  } catch {
    return "";
  }
  try {
    const buf = Buffer.allocUnsafe(size - start);
    const n = readSync(fd, buf, 0, buf.length, start);
    return buf.subarray(0, n).toString("utf8");
  } catch {
    return "";
  } finally {
    closeSync(fd);
  }
}

/**
 * 初回だけログを広く遡ってメタ情報を拾う。
 * ai-title / last-prompt はセッション中に数回しか現れず、末尾読みだけでは取りこぼす。
 */
export function primeMeta(path: string): { title?: string; lastPrompt?: string } {
  const out: { title?: string; lastPrompt?: string } = {};
  for (const line of readTail(path, MAX_SCAN_BYTES).split("\n")) {
    // 全行を JSON パースすると重いので、対象の type を含む行だけに絞る。
    if (!line.includes('"ai-title"') && !line.includes('"last-prompt"')) continue;
    const ev = parseLine(line);
    if (!ev) continue;
    if (ev.title) out.title = ev.title;
    if (ev.lastPrompt) out.lastPrompt = ev.lastPrompt;
  }
  return out;
}

/**
 * 1 セッション分のログを差分で読む。
 * 初回は末尾だけを読んで現在の状態を復元し、以降は追記分のみを返す。
 */
export class TranscriptReader {
  private offset = 0;
  private carry = "";
  private primed = false;
  // 読み取り境界に跨がったマルチバイト文字を持ち越す（string で持つと U+FFFD に潰れる）。
  private decoder = new StringDecoder("utf8");

  constructor(readonly path: string) {}

  private reset(): void {
    this.offset = 0;
    this.carry = "";
    this.primed = false;
    this.decoder = new StringDecoder("utf8");
  }

  /** サイズが変わっていなければ何もしない。追記分をパースして返す。 */
  read(): ParsedEvent[] {
    let size: number;
    try {
      size = statSync(this.path).size;
    } catch {
      return [];
    }

    if (size < this.offset) this.reset(); // ローテートや切り詰め
    if (size === this.offset && this.primed) return [];

    let start = this.offset;
    let dropFirstLine = false;
    if (!this.primed) {
      start = Math.max(0, size - BOOTSTRAP_BYTES);
      if (start > 0) {
        // 直前の 1 バイトも読む。それが改行なら分割後の先頭が空文字になり、行を失わない。
        start -= 1;
        dropFirstLine = true;
      }
    }
    if (size <= start) {
      this.offset = size;
      this.primed = true;
      return [];
    }

    let fd: number;
    try {
      fd = openSync(this.path, "r");
    } catch {
      return [];
    }
    let bytes = 0;
    let buf: Buffer;
    try {
      buf = Buffer.allocUnsafe(size - start);
      bytes = readSync(fd, buf, 0, buf.length, start);
    } catch {
      return [];
    } finally {
      closeSync(fd);
    }

    this.offset = start + bytes;
    const chunk = this.decoder.write(buf.subarray(0, bytes));
    const lines = (this.carry + chunk).split("\n");
    this.carry = lines.pop() ?? ""; // 最後は書き込み途中の可能性があるので持ち越す
    if (dropFirstLine) lines.shift();
    this.primed = true;

    const events: ParsedEvent[] = [];
    for (const line of lines) {
      if (!line.trim()) continue;
      const ev = parseLine(line);
      if (ev) events.push(ev);
    }
    return events;
  }
}
