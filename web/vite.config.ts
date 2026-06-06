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
    proxy: {
      "/api": "http://localhost:8765",
    },
  },
});
