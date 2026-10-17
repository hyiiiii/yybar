import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  build: { outDir: "dist" },
  server: {
    // 开发时前端跑在 5173，接口转给 wrangler dev（8787）
    proxy: { "/api": "http://localhost:8787", "/auth": "http://localhost:8787" },
  },
});
