import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

/** javascript: などを踏まないよう、開くのは http(s) だけに限る。 */
const SAFE_HREF = /^https?:\/\//i;

/**
 * フィード用の Markdown。生 HTML は react-markdown の既定どおり無効のまま扱う。
 * 幅が約 340px しかないので、はみ出しうる要素はすべて折り返すか横スクロールさせる。
 */
export function Markdown({ text }: { text: string }) {
  return (
    <div className="[&>*:first-child]:mt-0 [&>*:last-child]:mb-0">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
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
              <span className="break-all">{children}</span>
            ),
          code: ({ children, className }) =>
            // ブロックは pre 側で枠を付けるので、ここでは色だけ変える。
            className?.includes("language-") ? (
              <code className="font-mono text-[11px] text-slate-200">{children}</code>
            ) : (
              <code className="rounded bg-white/8 px-1 py-px font-mono text-[11px] text-slate-200">
                {children}
              </code>
            ),
          pre: ({ children }) => (
            <pre className="my-1 overflow-x-auto rounded border border-white/8 bg-black/30 p-2">
              {children}
            </pre>
          ),
          ul: ({ children }) => <ul className="my-1 list-disc pl-4">{children}</ul>,
          ol: ({ children }) => <ol className="my-1 list-decimal pl-4">{children}</ol>,
          li: ({ children }) => <li className="my-0.5 break-words">{children}</li>,
          // 見出しが来ても行が跳ねないよう、本文と同じ大きさに抑えて太さだけ変える。
          h1: ({ children }) => <div className="mt-1.5 font-semibold text-slate-200">{children}</div>,
          h2: ({ children }) => <div className="mt-1.5 font-semibold text-slate-200">{children}</div>,
          h3: ({ children }) => <div className="mt-1.5 font-semibold text-slate-200">{children}</div>,
          h4: ({ children }) => <div className="mt-1.5 font-semibold text-slate-200">{children}</div>,
          h5: ({ children }) => <div className="mt-1.5 font-semibold text-slate-200">{children}</div>,
          h6: ({ children }) => <div className="mt-1.5 font-semibold text-slate-200">{children}</div>,
          strong: ({ children }) => <strong className="font-semibold text-slate-200">{children}</strong>,
          blockquote: ({ children }) => (
            <blockquote className="my-1 border-l-2 border-white/15 pl-2 text-slate-500">
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
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  );
}
