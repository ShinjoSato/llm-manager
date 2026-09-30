// 1 セッション分のステージだけを描く埋め込み表示（mac アプリの WKWebView から読む）。
import { lazy, Suspense, useLayoutEffect, useRef, useState } from "react";
import type { SessionSnapshot } from "../../../src/types.js";
import { AgentStage } from "../pixel/AgentStage.js";
import { useMonitor, useNow } from "../useMonitor.js";
import { stageScale, parseEmbedParams, type EmbedParams } from "./params.js";
import "./embed.css";

// 3D を指定された時だけ three.js を読み込む。
const Stage3DCanvas = lazy(() => import("../three/Stage3DCanvas.js"));

export function EmbedStage() {
  const [params] = useState(() => parseEmbedParams(window.location.search));
  const { sessions } = useMonitor();

  useLayoutEffect(() => {
    const root = document.documentElement;
    root.classList.add("embed");
    root.style.setProperty("--embed-bg", params?.background ?? "transparent");
  }, [params]);

  if (!params) return <Note text="session を指定してください" />;
  const session = sessions.find((s) => s.sessionId === params.sessionId);
  // 初回の SSE が届くまでは何も出さない（「見つかりません」が一瞬見えるのを防ぐ）。
  if (!session) return sessions.length ? <Note text="セッションが見つかりません" /> : null;
  return <Stage session={session} params={params} />;
}

function Stage({ session, params }: { session: SessionSnapshot; params: EmbedParams }) {
  if (params.mode === "3d") {
    return (
      <div className="absolute inset-0">
        <Suspense fallback={null}>
          <Stage3DCanvas mode="world" sessions={[session]} />
        </Suspense>
      </div>
    );
  }
  return <FlatStage session={session} />;
}

/** 2D は自然寸法で描いてから、枠に収まる倍率で拡大縮小する（ドット絵なので SVG のまま鮮明）。 */
function FlatStage({ session }: { session: SessionSnapshot }) {
  const now = useNow();
  const box = useRef<HTMLDivElement>(null);
  const inner = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);

  useLayoutEffect(() => {
    const b = box.current;
    const i = inner.current;
    if (!b || !i) return;
    const update = () =>
      setScale(
        stageScale(
          { width: i.offsetWidth, height: i.offsetHeight },
          // 端に張り付かないよう 1 割の余白を残す。
          { width: b.clientWidth * 0.9, height: b.clientHeight * 0.9 },
        ),
      );
    update();
    const ro = new ResizeObserver(update);
    ro.observe(b);
    ro.observe(i);
    return () => ro.disconnect();
  }, []);

  return (
    <div ref={box} className="absolute inset-0 flex items-center justify-center overflow-hidden">
      <div ref={inner} className="w-max" style={{ transform: `scale(${scale})` }}>
        <AgentStage session={session} now={now} />
      </div>
    </div>
  );
}

function Note({ text }: { text: string }) {
  return (
    <div className="absolute inset-0 flex items-center justify-center text-[12px] text-slate-500">
      {text}
    </div>
  );
}
