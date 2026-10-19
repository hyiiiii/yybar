//! 托盘图标：32×32 圆角方块，底色按最紧张那档额度的剩余比例分四档，上面写剩余百分比。
//! 没有数据时是灰底「--」。

/// 状态色（和 `docs/设计风格.md` §4.3 一致的四档，托盘底色在任务栏上统一用浅色那组）
pub fn status_rgb(remaining: Option<f64>) -> [u8; 3] {
    match remaining {
        None => [0x8E, 0x8E, 0x93],
        Some(r) if r <= 0.0 => [0xFF, 0x4D, 0x6D],
        Some(r) if r < 20.0 => [0xFF, 0x7A, 0x2F],
        Some(r) if r <= 50.0 => [0xF6, 0xC3, 0x43],
        Some(_) => [0x6C, 0x6C, 0x70],
    }
}

/// 3×5 点阵数字
const GLYPHS: [[u8; 5]; 11] = [
    [0b111, 0b101, 0b101, 0b101, 0b111], // 0
    [0b010, 0b110, 0b010, 0b010, 0b111], // 1
    [0b111, 0b001, 0b111, 0b100, 0b111], // 2
    [0b111, 0b001, 0b111, 0b001, 0b111], // 3
    [0b101, 0b101, 0b111, 0b001, 0b001], // 4
    [0b111, 0b100, 0b111, 0b001, 0b111], // 5
    [0b111, 0b100, 0b111, 0b101, 0b111], // 6
    [0b111, 0b001, 0b010, 0b010, 0b010], // 7
    [0b111, 0b101, 0b111, 0b101, 0b111], // 8
    [0b111, 0b101, 0b111, 0b001, 0b111], // 9
    [0b000, 0b000, 0b111, 0b000, 0b000], // -
];

pub const SIZE: u32 = 32;

pub fn render(remaining: Option<f64>) -> Vec<u8> {
    let n = SIZE as usize;
    let mut px = vec![0u8; n * n * 4];
    let [r, g, b] = status_rgb(remaining);
    // 黄色底上用深色字，其余用白字
    let ink: [u8; 3] = if remaining.is_some_and(|v| (20.0..=50.0).contains(&v)) { [0x1D, 0x1D, 0x1F] } else { [0xFF, 0xFF, 0xFF] };

    // 圆角方块（半径 7，边缘做简单抗锯齿）
    let radius = 7.0f32;
    for y in 0..n {
        for x in 0..n {
            let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
            let cx = fx.clamp(radius, n as f32 - radius);
            let cy = fy.clamp(radius, n as f32 - radius);
            let d = ((fx - cx).powi(2) + (fy - cy).powi(2)).sqrt();
            let alpha = (radius + 0.5 - d).clamp(0.0, 1.0);
            if alpha > 0.0 {
                let i = (y * n + x) * 4;
                px[i..i + 4].copy_from_slice(&[r, g, b, (alpha * 255.0) as u8]);
            }
        }
    }

    let digits: Vec<usize> = match remaining {
        None => vec![10, 10],
        Some(v) => (v.round().clamp(0.0, 100.0) as u32).to_string().bytes().map(|c| (c - b'0') as usize).collect(),
    };
    // 两位数放大 4 倍（12×20），三位数（100）放大 3 倍
    let scale = if digits.len() >= 3 { 3 } else { 4 };
    let gap = 2;
    let width = digits.len() * 3 * scale + (digits.len() - 1) * gap;
    let height = 5 * scale;
    let ox = (n - width) / 2;
    let oy = (n - height) / 2;
    for (k, d) in digits.iter().enumerate() {
        let gx = ox + k * (3 * scale + gap);
        for (row, bits) in GLYPHS[*d].iter().enumerate() {
            for col in 0..3 {
                if bits & (0b100 >> col) == 0 {
                    continue;
                }
                for dy in 0..scale {
                    for dx in 0..scale {
                        let x = gx + col * scale + dx;
                        let y = oy + row * scale + dy;
                        let i = (y * n + x) * 4;
                        px[i..i + 4].copy_from_slice(&[ink[0], ink[1], ink[2], 255]);
                    }
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
    fn renders_all_widths() {
        for v in [None, Some(0.0), Some(7.0), Some(42.0), Some(100.0)] {
            assert_eq!(render(v).len(), (SIZE * SIZE * 4) as usize);
        }
    }

    #[test]
    fn status_bands() {
        assert_eq!(status_rgb(Some(0.0)), [0xFF, 0x4D, 0x6D]);
        assert_eq!(status_rgb(Some(19.0)), [0xFF, 0x7A, 0x2F]);
        assert_eq!(status_rgb(Some(50.0)), [0xF6, 0xC3, 0x43]);
        assert_eq!(status_rgb(Some(51.0)), [0x6C, 0x6C, 0x70]);
    }
}
