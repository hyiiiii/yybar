// 对应 Mac `Core/L10n.swift`：界面只显示一种语言，`tr(en, zh)` 按设置选词（跟随系统由后台解析好）。

let chinese = (typeof navigator !== "undefined" ? navigator.language : "zh").toLowerCase().startsWith("zh");

export function setChinese(value: boolean) {
  chinese = value;
  if (typeof document !== "undefined") document.documentElement.lang = value ? "zh-CN" : "en";
}

export function isChinese() {
  return chinese;
}

export function tr(en: string, zh: string): string {
  return chinese ? zh : en;
}
