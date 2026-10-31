// 右键悬浮窗弹出的菜单（对应 Mac `FloatingMenuController`）：统计 / 设置 / bar，和悬浮窗样式（简略 / 详细 / 隐藏，勾着当前的）。
// 自己画、不用系统菜单：底色、描边、圆角和悬浮窗一样，每项前面有图标。窗口由后台放在光标处（windows.rs show_floating_menu），
// 点了某项、点到别处（窗口失焦）或按 Esc 就收起。

import { useEffect, useLayoutEffect, useRef } from "react";
import { api, useAppState } from "../shared/api";
import { Icon } from "../shared/design";
import { tr } from "../shared/l10n";

type Item = { id: string; icon: string | null; label: string };

export function FloatingMenu() {
  const state = useAppState();
  const ref = useRef<HTMLDivElement>(null);

  // 窗口刚好包住菜单
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const fit = () => {
      const r = el.getBoundingClientRect();
      api.fitFloatingMenu(Math.ceil(r.width), Math.ceil(r.height));
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && api.hideFloatingMenu();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const style = state?.settings.floatingStyle ?? "compact";
  const open: Item[] = [
    { id: "floating-stats", icon: "chart", label: tr("Statistics", "统计") },
    { id: "floating-settings", icon: "gear", label: tr("Settings", "设置") },
    { id: "floating-bar", icon: "cards", label: "bar" },
  ];
  const styles: Item[] = [
    { id: "floating-compact", icon: style === "compact" ? "check" : null, label: tr("Compact", "简略") },
    { id: "floating-detailed", icon: style === "detailed" ? "check" : null, label: tr("Detailed", "详细") },
    { id: "floating-hidden", icon: style === "hidden" ? "check" : null, label: tr("Hide", "隐藏") },
  ];
  const row = (it: Item) => (
    <button key={it.id} className="fmenu-item" onClick={() => api.pickFloatingMenu(it.id)}>
      <span className="fmenu-icon">{it.icon && <Icon name={it.icon} size={14} />}</span>
      {it.label}
    </button>
  );
  return (
    <div ref={ref} className="fmenu">
      {open.map(row)}
      <div className="fmenu-sep" />
      {styles.map(row)}
    </div>
  );
}
