// フィードの Markdown 描画。記法が効くことより、危険なものを通さないことが主眼。
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "../src/components/Markdown.js";

let ok = 0;
let ng = 0;

function t(name: string, text: string, want: (html: string) => boolean): void {
  const html = renderToStaticMarkup(React.createElement(Markdown, { text }));
  const pass = want(html);
  pass ? ok++ : ng++;
  console.log(`  ${pass ? "OK  " : "NG  "}${name.padEnd(48)}${pass ? "" : html.slice(0, 200)}`);
}

// ── 記法が効く ──
t("**太字** が strong になる", "これは **重要** です", (h) => h.includes("<strong"));
t("`コード` が code になる", "`develop` を更新", (h) => h.includes("<code"));
t("リンクが別タブで開く", "[#956](https://example.com/x)", (h) =>
  h.includes('target="_blank"') && h.includes('rel="noopener noreferrer"'),
);
t("箇条書きが li になる", "- ひとつ\n- ふたつ", (h) => h.includes("<li"));

// ── 危険なものを通さない ──
t("javascript: は a にしない", "[click](javascript:alert(1))", (h) =>
  !h.toLowerCase().includes("javascript:") && !h.includes("<a "),
);
t("data: も弾く", "[x](data:text/html;base64,PHNjcmlwdD4=)", (h) => !h.includes("<a "));
t("vbscript: も弾く", "[x](vbscript:msgbox(1))", (h) => !h.includes("<a "));
t("プロトコル相対 // は弾く", "[x](//evil.example.com)", (h) => !h.includes("<a "));
t("script が要素にならずエスケープされる", "<script>alert(1)</script>", (h) =>
  !h.includes("<script") && h.includes("&lt;script&gt;"),
);
t("img の onerror が属性にならない", "<img src=x onerror=alert(1)>", (h) =>
  !h.includes("<img") && h.includes("&lt;img"),
);
t("a タグを直書きしても要素にならない", '<a href="javascript:alert(1)">x</a>', (h) =>
  !h.includes("<a ") && h.includes("&lt;a"),
);
t("画像記法はテキストに置き換わる", "![figure](https://example.com/a.png)", (h) =>
  !h.includes("<img") && h.includes("figure"),
);

// ── 160 文字で切られた壊れた記法 ──
t("閉じない ** はそのまま文字", "途中で切れた **太字", (h) => !h.includes("<strong"));
t("閉じないバッククォートもそのまま", "壊れた `code", (h) => !h.includes("<code"));
t("空文字でも落ちない", "", () => true);

// ── 狭い幅で崩れない ──
t("pre に横スクロールが付く", "```\nlong code\n```", (h) => h.includes("overflow-x-auto"));
t("表に横スクロール枠が付く", "| a | b |\n|---|---|\n| 1 | 2 |", (h) =>
  h.includes("overflow-x-auto"),
);
t("見出しを大きくしない", "# 見出し", (h) => !h.includes("<h1") && h.includes("見出し"));

// ── ログによく出る文字列が化けない ──
t("~/.claude が打ち消し線にならない", "~/.claude と ~/project を見る", (h) => !h.includes("<del"));
t("二重チルダは打ち消し線のまま", "~~取り消し~~", (h) => h.includes("<del"));

console.log(`\n  ${ng === 0 ? "PASS" : "FAIL"}: ${ok} 件成功 / ${ng} 件失敗`);
if (ng) process.exitCode = 1;
