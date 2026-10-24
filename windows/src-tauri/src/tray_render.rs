//! 托盘图标绘制（对应 Mac `MenuBarLabel` 的 logo + 百分比）。
//!
//! Windows 任务栏只能放方形小图标、不能写文字，所以每个服务一个托盘图标（32×32）：
//! - 底是该服务的 tile（和 App 里的 ServiceTile 一样：Codex 白底、Claude 桃橙、Grok 黑、Antigravity 白底彩虹 logo）；
//! - 中间是剩余百分比（系统 Segoe UI 字体；找不到时用内置点阵数字）；
//! - 底部一条细进度条按 4 档状态色（剩余 >50% 灰、20%~50% 黄、<20% 橙、=0 红）。
//! 「使用中」时数字和 logo 交替淡入淡出（1.6 秒一周期，对应 Mac 的图标呼吸）；等待审批时一直显示 logo；还没有数据时也显示 logo。

use std::sync::OnceLock;

use ab_glyph::{Font, FontVec, PxScale, ScaleFont};
use resvg::{tiny_skia, usvg};

use yybar_core::UsageApp;

pub const SIZE: u32 = 32;
const N: usize = SIZE as usize;

#[derive(Clone, Copy)]
struct Palette {
    bg: [u8; 3],
    fg: [u8; 3],
    border: [u8; 4],
}

fn palette(app: UsageApp) -> Palette {
    match app {
        UsageApp::Codex => Palette { bg: [0xFF, 0xFF, 0xFF], fg: [0x11, 0x11, 0x11], border: [0, 0, 0, 70] },
        UsageApp::Claude => Palette { bg: [0xD9, 0x77, 0x57], fg: [0xFF, 0xFF, 0xFF], border: [0, 0, 0, 0] },
        UsageApp::Grok => Palette { bg: [0x1D, 0x1D, 0x1F], fg: [0xFF, 0xFF, 0xFF], border: [255, 255, 255, 90] },
        UsageApp::Agy => Palette { bg: [0xFF, 0xFF, 0xFF], fg: [0x4A, 0x86, 0xE8], border: [0, 0, 0, 70] },
    }
}

/// 4 档状态色（设计风格 §4.3，托盘上统一用浅色那组）。
pub fn status_rgb(remaining: f64, normal: [u8; 3]) -> [u8; 3] {
    if remaining <= 0.0 {
        [0xFF, 0x4D, 0x6D]
    } else if remaining < 20.0 {
        [0xFF, 0x7A, 0x2F]
    } else if remaining <= 50.0 {
        [0xF6, 0xC3, 0x43]
    } else {
        normal
    }
}

// ---------- logo ----------

fn logo_svg(app: UsageApp) -> &'static str {
    match app {
        UsageApp::Codex => include_str!("../../../Resources/Logos/codex.svg"),
        UsageApp::Claude => include_str!("../../../Resources/Logos/claude.svg"),
        UsageApp::Grok => include_str!("../../../Resources/Logos/grok.svg"),
        UsageApp::Agy => include_str!("../../../Resources/Logos/agy-color.svg"),
    }
}

/// logo 栅格化成 RGBA（预乘前的直通色），size×size。单色 logo 的颜色由调用方按 alpha 重新上色。
fn raster_logo(app: UsageApp, size: u32) -> Option<Vec<u8>> {
    let tree = usvg::Tree::from_str(logo_svg(app), &usvg::Options::default()).ok()?;
    let mut pixmap = tiny_skia::Pixmap::new(size, size)?;
    let ts = tree.size();
    let scale = (size as f32 / ts.width()).min(size as f32 / ts.height());
    let dx = (size as f32 - ts.width() * scale) / 2.0;
    let dy = (size as f32 - ts.height() * scale) / 2.0;
    resvg::render(&tree, tiny_skia::Transform::from_row(scale, 0.0, 0.0, scale, dx, dy), &mut pixmap.as_mut());
    // tiny-skia 是预乘 alpha，转回直通色
    let mut data = pixmap.take();
    for px in data.chunks_exact_mut(4) {
        let a = px[3] as f32 / 255.0;
        if a > 0.0 {
            for c in &mut px[..3] {
                *c = ((*c as f32 / a).min(255.0)) as u8;
            }
        }
    }
    Some(data)
}

fn logo(app: UsageApp) -> Option<&'static (u32, Vec<u8>)> {
    static CACHE: OnceLock<Vec<Option<(u32, Vec<u8>)>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| {
        UsageApp::ALL
            .iter()
            .map(|a| {
                let size = if *a == UsageApp::Agy { 22 } else { 20 };
                raster_logo(*a, size).map(|d| (size, d))
            })
            .collect()
    });
    cache[UsageApp::ALL.iter().position(|a| *a == app)?].as_ref()
}

// ---------- 字体 ----------

fn font() -> Option<&'static FontVec> {
    static FONT: OnceLock<Option<FontVec>> = OnceLock::new();
    FONT.get_or_init(|| {
        let mut candidates = Vec::new();
        if let Some(windir) = std::env::var_os("WINDIR") {
            let fonts = std::path::PathBuf::from(windir).join("Fonts");
            for name in ["seguisb.ttf", "segoeuib.ttf", "segoeui.ttf", "arialbd.ttf"] {
                candidates.push(fonts.join(name));
            }
        }
        for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/System/Library/Fonts/SFNS.ttf"] {
            candidates.push(p.into());
        }
        candidates.into_iter().find_map(|p| std::fs::read(p).ok().and_then(|d| FontVec::try_from_vec(d).ok()))
    })
    .as_ref()
}

/// 3×5 点阵数字（找不到系统字体时用）
const GLYPHS: [[u8; 5]; 11] = [
    [0b111, 0b101, 0b101, 0b101, 0b111],
    [0b010, 0b110, 0b010, 0b010, 0b111],
    [0b111, 0b001, 0b111, 0b100, 0b111],
    [0b111, 0b001, 0b111, 0b001, 0b111],
    [0b101, 0b101, 0b111, 0b001, 0b001],
    [0b111, 0b100, 0b111, 0b001, 0b111],
    [0b111, 0b100, 0b111, 0b101, 0b111],
    [0b111, 0b001, 0b010, 0b010, 0b010],
    [0b111, 0b101, 0b111, 0b101, 0b111],
    [0b111, 0b101, 0b111, 0b001, 0b111],
    [0b000, 0b000, 0b111, 0b000, 0b000],
];

/// 文字覆盖率（0~1），居中在 (cx, cy)。
fn text_mask(text: &str) -> Vec<f32> {
    let mut mask = vec![0f32; N * N];
    let (cx, cy) = (N as f32 / 2.0, 13.5f32);
    if let Some(font) = font() {
        let px = if text.len() >= 3 { 15.0 } else { 20.0 };
        let scaled = font.as_scaled(PxScale::from(px));
        let width: f32 = text.chars().map(|c| scaled.h_advance(font.glyph_id(c))).sum::<f32>() - 0.5 * (text.len() as f32 - 1.0);
        let digit_height = font
            .outline_glyph(font.glyph_id('0').with_scale_and_position(PxScale::from(px), ab_glyph::point(0.0, 0.0)))
            .map(|g| g.px_bounds().height())
            .unwrap_or(px * 0.7);
        let baseline = cy + digit_height / 2.0;
        let mut x = cx - width / 2.0;
        for c in text.chars() {
            let id = font.glyph_id(c);
            let glyph = id.with_scale_and_position(PxScale::from(px), ab_glyph::point(x, baseline));
            x += scaled.h_advance(id) - 0.5;
            let Some(outline) = font.outline_glyph(glyph) else { continue };
            let b = outline.px_bounds();
            outline.draw(|gx, gy, cov| {
                let (px, py) = (b.min.x as i32 + gx as i32, b.min.y as i32 + gy as i32);
                if (0..N as i32).contains(&px) && (0..N as i32).contains(&py) {
                    let m = &mut mask[py as usize * N + px as usize];
                    *m = (*m + cov).min(1.0);
                }
            });
        }
        return mask;
    }
    let digits: Vec<usize> = text.chars().map(|c| c.to_digit(10).map(|d| d as usize).unwrap_or(10)).collect();
    let scale = if digits.len() >= 3 { 3 } else { 4 };
    let gap = scale;
    let total_w = digits.len() * 3 * scale + (digits.len() - 1) * gap;
    let x0 = (N - total_w) / 2;
    let y0 = (cy as usize).saturating_sub(5 * scale / 2);
    for (i, d) in digits.iter().enumerate() {
        let gx = x0 + i * (3 * scale + gap);
        for (row, bits) in GLYPHS[*d].iter().enumerate() {
            for col in 0..3 {
                if bits & (0b100 >> col) != 0 {
                    for dy in 0..scale {
                        for dx in 0..scale {
                            let (x, y) = (gx + col * scale + dx, y0 + row * scale + dy);
                            if x < N && y < N {
                                mask[y * N + x] = 1.0;
                            }
                        }
                    }
                }
            }
        }
    }
    mask
}

// ---------- 合成 ----------

fn blend(px: &mut [u8], rgb: [u8; 3], alpha: f32) {
    if alpha <= 0.0 {
        return;
    }
    let a = alpha.clamp(0.0, 1.0);
    let dst_a = px[3] as f32 / 255.0;
    let out_a = a + dst_a * (1.0 - a);
    for i in 0..3 {
        let c = (rgb[i] as f32 * a + px[i] as f32 * dst_a * (1.0 - a)) / out_a.max(1e-6);
        px[i] = c.round().clamp(0.0, 255.0) as u8;
    }
    px[3] = (out_a * 255.0).round() as u8;
}

/// 圆角矩形覆盖率（简单抗锯齿）。
fn rounded(x: usize, y: usize, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) -> f32 {
    let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
    let cx = fx.clamp(x0 + r, x1 - r);
    let cy = fy.clamp(y0 + r, y1 - r);
    let d = ((fx - cx).powi(2) + (fy - cy).powi(2)).sqrt();
    let inside_x = (fx - x0).min(x1 - fx) + 0.5;
    let inside_y = (fy - y0).min(y1 - fy) + 0.5;
    (r + 0.5 - d).clamp(0.0, 1.0).min(inside_x.clamp(0.0, 1.0)).min(inside_y.clamp(0.0, 1.0))
}

/// 画一个服务的托盘图标。`remaining` 为 None 时还没有数据；`logo_phase` 0 = 数字、1 = logo。
pub fn render(app: UsageApp, remaining: Option<f64>, logo_phase: f32) -> Vec<u8> {
    let pal = palette(app);
    let mut px = vec![0u8; N * N * 4];
    let r = 7.0;
    for y in 0..N {
        for x in 0..N {
            let cov = rounded(x, y, 0.0, 0.0, N as f32, N as f32, r);
            if cov > 0.0 {
                let i = (y * N + x) * 4;
                blend(&mut px[i..i + 4], pal.bg, cov);
                if pal.border[3] > 0 {
                    let inner = rounded(x, y, 1.0, 1.0, N as f32 - 1.0, N as f32 - 1.0, r - 1.0);
                    let edge = (cov - inner).max(0.0);
                    blend(&mut px[i..i + 4], [pal.border[0], pal.border[1], pal.border[2]], edge * pal.border[3] as f32 / 255.0);
                }
            }
        }
    }

    let phase = if remaining.is_none() { 1.0 } else { logo_phase.clamp(0.0, 1.0) };
    // 数字层
    if phase < 1.0 {
        let value = remaining.unwrap_or(0.0).round().clamp(0.0, 100.0) as u32;
        let mask = text_mask(&value.to_string());
        for (i, m) in mask.iter().enumerate() {
            if *m > 0.0 {
                blend(&mut px[i * 4..i * 4 + 4], pal.fg, m * (1.0 - phase));
            }
        }
    }
    // logo 层
    if phase > 0.0 {
        if let Some((size, data)) = logo(app) {
            let size = *size as usize;
            let off_x = (N - size) / 2;
            let off_y = if remaining.is_some() { (N - size) / 2 - 2 } else { (N - size) / 2 };
            for y in 0..size {
                for x in 0..size {
                    let s = &data[(y * size + x) * 4..(y * size + x) * 4 + 4];
                    if s[3] == 0 {
                        continue;
                    }
                    let rgb = if app == UsageApp::Agy { [s[0], s[1], s[2]] } else { pal.fg };
                    let i = ((y + off_y) * N + x + off_x) * 4;
                    blend(&mut px[i..i + 4], rgb, s[3] as f32 / 255.0 * phase);
                }
            }
        }
    }
    // 底部进度条
    if let Some(rem) = remaining {
        let (x0, x1, y0, y1) = (5.0f32, N as f32 - 5.0, 26.0f32, 29.0f32);
        let track = if pal.bg[0] > 128 { [0u8, 0, 0] } else { [255u8, 255, 255] };
        let normal = if pal.bg[0] > 128 { [0x6C, 0x6C, 0x70] } else { [0xC7, 0xC7, 0xCC] };
        let color = status_rgb(rem, normal);
        let fill_end = x0 + (x1 - x0) * (rem / 100.0).clamp(0.0, 1.0) as f32;
        for y in 0..N {
            for x in 0..N {
                let cov = rounded(x, y, x0, y0, x1, y1, 1.5);
                if cov <= 0.0 {
                    continue;
                }
                let i = (y * N + x) * 4;
                blend(&mut px[i..i + 4], track, cov * 0.18);
                if rem > 0.0 {
                    let fill = rounded(x, y, x0, y0, fill_end.max(x0 + 3.0), y1, 1.5);
                    blend(&mut px[i..i + 4], color, fill);
                }
            }
        }
    }
    px
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_all() {
        for app in UsageApp::ALL {
            assert!(logo(app).is_some(), "{app:?} logo");
            let px = render(app, Some(42.0), 0.0);
            assert_eq!(px.len(), N * N * 4);
            let _ = render(app, None, 0.0);
            let _ = render(app, Some(100.0), 0.5);
        }
    }
}
