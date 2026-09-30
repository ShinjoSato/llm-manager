// 埋め込み表示の指定。`/?embed=stage&session=<id>&mode=2d|3d&bg=transparent|<hex>`

export type EmbedMode = "2d" | "3d";

export interface EmbedParams {
  sessionId: string;
  mode: EmbedMode;
  /** CSS の色。transparent なら親（WKWebView）の背景が透ける。 */
  background: string;
}

/** 埋め込み表示でなければ null。session が無い時も表示するもの自体が無いので null。 */
export function parseEmbedParams(search: string): EmbedParams | null {
  const q = new URLSearchParams(search);
  if (q.get("embed") !== "stage") return null;
  const sessionId = q.get("session")?.trim() ?? "";
  if (!sessionId) return null;
  const mode: EmbedMode = q.get("mode") === "3d" ? "3d" : "2d";
  // 任意の CSS 値は受けない。色は 16 進だけにする。
  const bg = q.get("bg")?.trim() ?? "";
  const hex = /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(bg)?.[1];
  return { sessionId, mode, background: hex ? `#${hex}` : "transparent" };
}

/** 埋め込み表示を開いた URL か。session が無くても空の画面で応える。 */
export function isEmbedUrl(search: string): boolean {
  return new URLSearchParams(search).get("embed") === "stage";
}

/** 自然寸法の絵を枠に収める倍率。拡大しすぎるとドットが粗く見えるので上限を置く。 */
export function stageScale(
  natural: { width: number; height: number },
  box: { width: number; height: number },
  max = 4,
): number {
  if (natural.width <= 0 || natural.height <= 0 || box.width <= 0 || box.height <= 0) return 1;
  return Math.min(box.width / natural.width, box.height / natural.height, max);
}
