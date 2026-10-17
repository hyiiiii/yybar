// 把 dist-demo 打成一个自包含的 HTML 片段（预览用，数据全是示例）。
import { readFileSync, readdirSync, writeFileSync } from "node:fs";

const dir = new URL("../dist-demo/", import.meta.url);
const assets = readdirSync(new URL("assets/", dir));
const js = assets.filter((f) => f.endsWith(".js")).map((f) => readFileSync(new URL(`assets/${f}`, dir), "utf8")).join("\n");
const css = assets.filter((f) => f.endsWith(".css")).map((f) => readFileSync(new URL(`assets/${f}`, dir), "utf8")).join("\n");

const icon = `data:image/png;base64,${readFileSync(new URL("../../Resources/Assets.xcassets/AppIcon.appiconset/icon_64.png", import.meta.url)).toString("base64")}`;
const html = `<title>yybar 酒吧预览</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>${css}</style>
<div id="root"></div>
<script type="module">${js.replace(/<\/script/g, "<\\/script").replaceAll("/icon.png", icon)}</script>
`;
writeFileSync(new URL("yybar-preview.html", dir), html);
console.log(`dist-demo/yybar-preview.html ${(html.length / 1024).toFixed(0)} KB`);
