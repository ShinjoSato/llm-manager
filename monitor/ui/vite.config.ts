import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { resolve } from "node:path";

// ../src/types.ts を ui の外から import するため fs.allow に親を追加。
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5174,
    fs: { allow: [resolve(__dirname, "..")] },
    proxy: {
      "/api": "http://localhost:8766",
      "/events": "http://localhost:8766",
      "/hook": "http://localhost:8766",
    },
  },
});
