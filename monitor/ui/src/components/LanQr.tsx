import { Check, Copy, QrCode, X } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";

interface LanInfo {
  enabled: boolean;
  url: string | null;
}

/** この画面を手元で開いているか。IPv6 はブラケット付きで location.hostname に入る。 */
function isLoopbackHost(hostname: string): boolean {
  return (
    hostname === "localhost" ||
    hostname === "::1" ||
    hostname === "[::1]" ||
    /^127\./.test(hostname)
  );
}

/**
 * 別端末を繋ぐための QR。手元（ループバック）で開いた時だけサーバーが案内を返すので、
 * LAN から開いた画面ではボタンごと出ない。
 */
export function LanQrButton() {
  const [info, setInfo] = useState<LanInfo | null>(null);
  const [open, setOpen] = useState(false);
  const close = useCallback(() => setOpen(false), []);

  useEffect(() => {
    // 手元以外には案内が出ない（サーバーが 404 にする）ので、そもそも叩かない。
    if (!isLoopbackHost(location.hostname)) return;
    let alive = true;
    void (async () => {
      try {
        const res = await fetch("/api/lan");
        if (!res.ok) return; // LAN 端末には 404 が返る
        const json = (await res.json()) as LanInfo;
        if (alive && json.enabled) setInfo(json);
      } catch {
        // 案内が取れないだけなので画面は通常どおり動かす
      }
    })();
    return () => {
      alive = false;
    };
  }, []);

  if (!info) return null;

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        title="同じ Wi-Fi の別端末から開くための QR を出す"
        aria-haspopup="dialog"
        aria-expanded={open}
        className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10px] transition ${
          open
            ? "border-cyan-400/30 bg-cyan-400/10 text-cyan-300"
            : "border-white/10 bg-white/5 text-slate-500 hover:bg-white/10"
        }`}
      >
        <QrCode size={10} />
        QR
      </button>
      {open && <LanQrDialog url={info.url} onClose={close} />}
    </>
  );
}

function LanQrDialog({ url, onClose }: { url: string | null; onClose: () => void }) {
  const closeButton = useRef<HTMLButtonElement>(null);
  const [broken, setBroken] = useState(false);

  // 毎秒の再描画で焦点を奪い返さないよう、初期フォーカスは開いた時の 1 回だけにする。
  useEffect(() => {
    closeButton.current?.focus();
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return createPortal(
    <div
      // 画面外クリックで閉じる。中身のクリックは伝播させない。
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
      className="fixed inset-0 z-50 grid place-items-center bg-black/60 p-6 backdrop-blur-sm"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-label="LAN 接続用の QR コード"
        className="glass w-full max-w-[380px] p-5"
      >
        <div className="mb-3 flex items-center gap-2">
          <div className="text-[12px] font-semibold uppercase tracking-[0.12em] text-slate-400">
            別端末から開く
          </div>
          <button
            ref={closeButton}
            onClick={onClose}
            aria-label="閉じる"
            className="ml-auto grid h-[26px] w-[26px] place-items-center rounded-lg border border-white/10
                       bg-white/5 text-slate-400 transition hover:bg-white/10"
          >
            <X size={13} />
          </button>
        </div>

        {url === null ? (
          <div className="py-6 text-center text-[12px] text-slate-400">
            LAN の IPv4 が見つかりません（Wi-Fi に繋がっていますか）
          </div>
        ) : (
          <>
            <div className="grid place-items-center rounded-xl bg-white p-3">
              {broken ? (
                <div className="p-8 text-[12px] text-slate-600">QR を読み込めませんでした</div>
              ) : (
                <img
                  src="/api/lan/qr.svg"
                  alt="LAN 接続用の QR コード"
                  width={280}
                  height={280}
                  onError={() => setBroken(true)}
                  className="h-[280px] w-[280px]"
                />
              )}
            </div>
            <p className="mt-3 text-[11px] text-slate-500">
              iPhone / iPad のカメラで読むと、この画面が別端末で開きます
            </p>
            <div className="mt-2 flex items-center gap-1.5">
              <code className="min-w-0 flex-1 truncate rounded-lg border border-white/10 bg-white/5 px-2.5 py-1.5
                               font-mono text-[11px] text-slate-300">
                {url}
              </code>
              <CopyButton text={url} />
            </div>
            <p className="mt-2 text-[11px] text-slate-500">
              URL にはトークンが入っています。渡した端末はこの画面を開けます
            </p>
          </>
        )}
      </div>
    </div>,
    document.body,
  );
}

const RESET_DELAY_MS = 2_000;

function CopyButton({ text }: { text: string }) {
  const [phase, setPhase] = useState<"idle" | "copied" | "error">("idle");
  const timer = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(timer.current), []);

  async function copy() {
    window.clearTimeout(timer.current);
    try {
      await navigator.clipboard.writeText(text);
      setPhase("copied");
    } catch {
      setPhase("error");
    }
    timer.current = window.setTimeout(() => setPhase("idle"), RESET_DELAY_MS);
  }

  return (
    <button
      onClick={() => void copy()}
      aria-label="URL をコピー"
      title={phase === "error" ? "コピーできませんでした" : "URL をコピー"}
      className="grid h-[30px] w-[30px] shrink-0 place-items-center rounded-lg border border-white/10
                 bg-white/5 text-slate-300 transition hover:bg-white/10"
    >
      {phase === "copied" ? (
        <Check size={13} className="text-emerald-300" />
      ) : phase === "error" ? (
        <X size={13} className="text-rose-300" />
      ) : (
        <Copy size={13} />
      )}
    </button>
  );
}
