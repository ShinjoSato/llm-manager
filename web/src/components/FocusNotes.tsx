import { useState, useEffect } from "react";
import { NotebookPen, Check, Circle } from "lucide-react";
import type { ManagerState } from "../../../shared/types.js";
import { Card } from "./ui.js";

export function FocusNotes({
  state,
  onSave,
}: {
  state: ManagerState;
  onSave: (next: ManagerState) => void;
}) {
  const joined = state.focusNotes.join("\n");
  const [text, setText] = useState(joined);
  const [saved, setSaved] = useState(true);

  useEffect(() => {
    setText(joined);
    setSaved(true);
  }, [joined]);

  const commit = () => {
    const notes = text.split("\n").map((x) => x.trim()).filter(Boolean);
    onSave({ ...state, focusNotes: notes, updatedAt: new Date().toISOString().slice(0, 10) });
    setSaved(true);
  };

  return (
    <Card title="今日の重点" icon={<NotebookPen size={15} />} accent="text-emerald-300">
      <textarea
        className="min-h-28 w-full resize-y rounded-xl border border-white/10 bg-black/30 p-3 text-[13.5px] leading-relaxed text-slate-100 outline-none transition focus:border-emerald-400/40 focus:ring-2 focus:ring-emerald-400/15"
        value={text}
        onChange={(e) => {
          setText(e.target.value);
          setSaved(false);
        }}
        onBlur={commit}
        placeholder="1行 = 1項目。フォーカスを外すと保存されます。"
      />
      <div className={`mt-2 flex items-center gap-1.5 text-[11px] ${saved ? "text-emerald-300" : "text-amber-300"}`}>
        {saved ? <Check size={12} /> : <Circle size={9} className="fill-current" />}
        {saved ? "保存済み" : "未保存（フォーカスを外すと保存）"}
      </div>
    </Card>
  );
}
