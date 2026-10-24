import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({ mode }) => ({
  plugins: [react()],
  build: {
    outDir: mode === "demo" ? "dist-demo" : "dist",
    // 预览版要打成单个 HTML，不拆分代码块
    rollupOptions: mode === "demo" ? { output: { inlineDynamicImports: true } } : undefined,
  },
  server: {
    // 开发时前端跑在 5173，接口转给 wrangler dev（8787）
    proxy: { "/api": { target: "http://localhost:8787", ws: true }, "/auth": "http://localhost:8787" },
  },
}));
