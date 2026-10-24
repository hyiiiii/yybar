// 服务的显示名、识别色、logo（对应 Mac `DesignSystem.swift` 的 UsageApp 扩展）。

import codexSvg from "../../../Resources/Logos/codex.svg?raw";
import claudeSvg from "../../../Resources/Logos/claude.svg?raw";
import grokSvg from "../../../Resources/Logos/grok.svg?raw";
import agySvg from "../../../Resources/Logos/agy.svg?raw";
import agyColorSvg from "../../../Resources/Logos/agy-color.svg?raw";
import type { UsageApp } from "./types";

export const displayName: Record<UsageApp, string> = {
  codex: "Codex",
  claude: "Claude Code",
  grok: "Grok",
  agy: "Antigravity",
};

/** 统计页里的短名（Claude Code → Claude）。 */
export const shortName = (app: UsageApp) => (app === "claude" ? "Claude" : displayName[app]);

/** 识别色（CSS 变量，浅 / 深色各一套，见 base.css）。 */
export const accentVar: Record<UsageApp, string> = {
  codex: "var(--accent-codex)",
  claude: "var(--accent-claude)",
  grok: "var(--accent-grok)",
  agy: "var(--accent-google)",
};

export const providerName: Record<UsageApp, string> = {
  codex: "OpenAI",
  claude: "Anthropic",
  grok: "xAI",
  agy: "Google",
};

/** 单色 logo（填充改成 currentColor，跟随文字色）。 */
const mono = (svg: string) =>
  svg
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/fill="white"/g, 'fill="currentColor"')
    .replace(/width="100" height="100"/, 'width="100%" height="100%"');

export const monoLogo: Record<UsageApp, string> = {
  codex: mono(codexSvg),
  claude: mono(claudeSvg),
  grok: mono(grokSvg),
  agy: mono(agySvg),
};

/** 有彩色版的服务（Antigravity）。 */
export const colorLogo: Partial<Record<UsageApp, string>> = {
  agy: agyColorSvg.replace(/<!--[\s\S]*?-->/g, "").replace(/width="100" height="100"/, 'width="100%" height="100%"'),
};
