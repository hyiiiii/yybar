import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

// 五个页面：托盘弹出浮窗、主窗口（统计 + 设置）、桌面悬浮窗、悬浮窗的右键菜单、首次启动引导
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 5173, strictPort: true, fs: { allow: [".."] } },
  build: {
    target: "es2021",
    rollupOptions: {
      input: {
        popover: resolve(__dirname, "popover.html"),
        main: resolve(__dirname, "main.html"),
        floating: resolve(__dirname, "floating.html"),
        floatmenu: resolve(__dirname, "floatmenu.html"),
        onboarding: resolve(__dirname, "onboarding.html"),
      },
    },
  },
});
