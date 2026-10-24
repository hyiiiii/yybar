import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

// 两个页面：托盘弹出面板 index.html、悬浮条 pill.html
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 5173, strictPort: true },
  build: {
    target: "es2021",
    rollupOptions: {
      input: {
        panel: resolve(__dirname, "index.html"),
        pill: resolve(__dirname, "pill.html"),
      },
    },
  },
});
