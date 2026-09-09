// ドット絵の定義。"." は透明で、他の 1 文字がパレットのキーになる。
// 見た目をコード上でそのまま確認・編集できるよう、文字列の絵として持つ。

export type Sprite = readonly string[];

/** 親エージェント（立ち）。G=フード S=肌 K=目 B=胴 D=脚 */
export const AGENT_STAND: Sprite = [
  "....GGGG....",
  "...GGGGGG...",
  "..GGGGGGGG..",
  "..GGSSSSGG..",
  "..GSKSSKSG..",
  "..GSSSSSSG..",
  "...SSSSSS...",
  "....SSSS....",
  "...BBBBBB...",
  "..BBBBBBBB..",
  "..BBBBBBBB..",
  "..BBBBBBBB..",
  "...BBBBBB...",
  "...DD..DD...",
  "..DDD..DDD..",
];

/** 親エージェント（座り）。待機・終了で使う。 */
export const AGENT_SIT: Sprite = [
  "............",
  "............",
  "....GGGG....",
  "...GGGGGG...",
  "..GGGGGGGG..",
  "..GGSSSSGG..",
  "..GSKSSKSG..",
  "..GSSSSSSG..",
  "...SSSSSS...",
  "...BBBBBB...",
  "..BBBBBBBB..",
  "..BBBBBBBB..",
  "..BBBBBBBB..",
  ".DDBBBBBBDD.",
  ".DDDDDDDDDD.",
];

/** 親エージェント（うずくまり）。エラー時。頭を落として丸まった姿。 */
export const AGENT_DOWN: Sprite = [
  "............",
  "............",
  "............",
  "....GGGG....",
  "...GGGGGG...",
  "..GGGGGGGG..",
  "..GGSSSSGG..",
  "..GSKSSKSG..",
  "..GSSSSSSG..",
  "...SSSSSS...",
  "..BBBBBBBB..",
  ".BBBBBBBBBB.",
  ".BBBBBBBBBB.",
  ".BBBBBBBBBB.",
  ".DDDDDDDDDD.",
];

/** サブエージェント。C=明色 E=濃色 S=肌 K=目 F=脚 */
export const KID_STAND: Sprite = [
  "..CCCCCC..",
  ".CCCCCCCC.",
  ".CCSSSSCC.",
  ".CSKSSKSC.",
  ".CSSSSSSC.",
  "..SSSSSS..",
  "..EEEEEE..",
  ".EEEEEEEE.",
  ".EEEEEEEE.",
  "..EEEEEE..",
  "..FF..FF..",
  ".FFF..FFF.",
];

// ── 持ち物 ──────────────────────────────────────────
// K=枠 G=光る面 W=白 L=線 M=金属 T=柄 P=縁

/** 端末（Bash）。 */
export const ITEM_TERMINAL: Sprite = [
  "........",
  ".KKKKKK.",
  ".KGGGGK.",
  ".KGKGGK.",
  ".KGGKGK.",
  ".KGGGGK.",
  ".KKKKKK.",
  "..K..K..",
];

/** 本（Read / Grep / Glob）。 */
export const ITEM_BOOK: Sprite = [
  "........",
  ".WWWWWW.",
  ".WLLLLW.",
  ".WLWWLW.",
  ".WLLLLW.",
  ".WLWWLW.",
  ".WWWWWW.",
  "..KKKK..",
];

/** 巻物（Skill）。 */
export const ITEM_SCROLL: Sprite = [
  "..PPPP..",
  ".PWWWWP.",
  ".PWLLWP.",
  ".PWWWWP.",
  ".PWLLWP.",
  ".PWWWWP.",
  "..PPPP..",
  "........",
];

/** 槌（Edit / Write）。 */
export const ITEM_HAMMER: Sprite = [
  ".MMMMM..",
  ".MMMMM..",
  ".MMMMM..",
  "...TT...",
  "...TT...",
  "...TT...",
  "...TT...",
  "........",
];

/** 望遠鏡（WebFetch / WebSearch）。 */
export const ITEM_SCOPE: Sprite = [
  "......MM",
  ".....MM.",
  "....MM..",
  "...MM...",
  "..MM....",
  ".MM.....",
  "MM......",
  "........",
];

/** 問いかけ（AskUserQuestion）。 */
export const ITEM_QUESTION: Sprite = [
  "..GGGG..",
  ".GG..GG.",
  ".....GG.",
  "....GG..",
  "...GG...",
  "...GG...",
  "........",
  "...GG...",
];

/** 画布（Artifact）。 */
export const ITEM_CANVAS: Sprite = [
  ".KKKKKK.",
  ".KWWWWK.",
  ".KWGGWK.",
  ".KWGGWK.",
  ".KWWWWK.",
  ".KKKKKK.",
  "...TT...",
  "..TTTT..",
];

/** 巻いた紙（TodoWrite / 汎用）。 */
export const ITEM_NOTE: Sprite = [
  "........",
  ".WWWWWW.",
  ".WLLLLW.",
  ".WLLLLW.",
  ".WLLLLW.",
  ".WWWWWW.",
  "........",
  "........",
];

// ── 頭上のマーク ────────────────────────────────────
export const MARK_BANG: Sprite = ["A", "A", "A", ".", "A"];
export const MARK_QUESTION: Sprite = ["AAA", "..A", ".A.", "...", ".A."];
export const MARK_SLEEP: Sprite = ["AAA", "..A", ".A.", "A..", "AAA"];
