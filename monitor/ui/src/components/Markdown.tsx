import { memo } from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import type { PluggableList } from "unified";
import remarkGfm from "remark-gfm";

/** javascript: などを踏まないよう、開くのは http(s) だけに限る。 */
export const SAFE_HREF = /^https?:\/\//i;

// 単一チルダの打ち消しは切る。~/.claude のようなパスが化けるため。
const REMARK_PLUGINS: PluggableList = [[remarkGfm, { singleTilde: false }]];

/**
 * 要素の指定はモジュール定数にする。レンダーごとに作ると React が型の変化とみなし、
 * Markdown の DOM が毎回作り直される（選択やスクロール位置が飛ぶ）。
 */
const COMPONENTS: Components = {
  p: ({ children }) => <p className="my-1 break-words">{children}</p>,
  a: ({ href, children }) =>
    typeof href === "string" && SAFE_HREF.test(href) ? (
      <a
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        className="break-all text-cyan-300 underline decoration-cyan-300/30 hover:text-cyan-200"
      >
        {children}
      </a>
    ) : (
      // 開けないスキームでも、リンク先は title で確かめられるようにする。
      <span className="break-all" title={typeof href === "string" ? href : undefined}>
        {children}
      </span>
    ),
  // 中の code はインライン用の装飾を CSS で打ち消す（親を辿る判定は当てにならない）。
  pre: ({ children }) => (
    <pre className="my-1 overflow-x-auto rounded border border-white/8 bg-black/30 p-2 [&>code]:bg-transparent [&>code]:p-0">
      {children}
    </pre>
  ),
  code: ({ children }) => (
    <code className="rounded bg-white/8 px-1 py-px font-mono text-[11px] text-slate-200">
      {children}
    </code>
  ),
  ul: ({ children }) => <ul className="my-1 list-disc pl-4">{children}</ul>,
  ol: ({ children }) => <ol className="my-1 list-decimal pl-4">{children}</ol>,
  li: ({ children }) => <li className="my-0.5 break-words">{children}</li>,
  strong: ({ children }) => <strong className="font-semibold text-slate-200">{children}</strong>,
  blockquote: ({ children }) => (
    <blockquote className="my-1 break-words border-l-2 border-white/15 pl-2 text-slate-500">
      {children}
    </blockquote>
  ),
  table: ({ children }) => (
    <div className="my-1 overflow-x-auto">
      <table className="border-collapse text-[11px]">{children}</table>
    </div>
  ),
  th: ({ children }) => (
    <th className="border border-white/10 px-1.5 py-0.5 text-left font-semibold">{children}</th>
  ),
  td: ({ children }) => <td className="border border-white/10 px-1.5 py-0.5">{children}</td>,
  hr: () => <hr className="my-1.5 border-white/10" />,
  // 画像は出さない（外部への通信を増やさない）。
  img: ({ alt }) => <span className="text-slate-500">{alt ? `[${alt}]` : "[画像]"}</span>,
};

// 見出しが来ても行が跳ねないよう、本文と同じ大きさに抑えて太さだけ変える。
for (const tag of ["h1", "h2", "h3", "h4", "h5", "h6"] as const) {
  COMPONENTS[tag] = ({ children }) => (
    <div className="mt-1.5 break-words font-semibold text-slate-200">{children}</div>
  );
}

/**
 * フィード用の Markdown。生 HTML は react-markdown の既定どおり無効のまま扱う。
 * 幅が約 340px しかないので、はみ出しうる要素はすべて折り返すか横スクロールさせる。
 */
export const Markdown = memo(function Markdown({ text }: { text: string }) {
  return (
    <div className="[&>*:first-child]:mt-0 [&>*:last-child]:mb-0">
      <ReactMarkdown
        remarkPlugins={REMARK_PLUGINS}
        components={COMPONENTS}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
});
