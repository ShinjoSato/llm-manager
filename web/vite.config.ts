import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { resolve } from "node:path";

// ../shared を web の外から import するため fs.allow に親を追加。
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    fs: { allow: [resolve(__dirname, "..")] },
    // 文字列で書くと changeOrigin が既定で入り Host が転送先に書き換わる。
    // オブジェクト形式にするなら changeOrigin: true が要る（server の Host 検証で 403 になる）。
    proxy: {
      "/api": "http://localhost:8765",
    },
  },
});
