//! Converts Win32 cursor drawings over black and white into straight-alpha RGBA.

/// Normal alpha blending produces the same white-minus-black difference in all three channels.
/// An AND/XOR cursor can instead invert the desktop; give those pixels a contrasting outline.
pub fn from_black_and_white(width: u16, black: &[u8], white: &[u8]) -> Option<Vec<u8>> {
    let width = usize::from(width);
    if width == 0 || black.is_empty() || black.len() != white.len() || !black.len().is_multiple_of(width * 4) {
        return None;
    }
    let mut rgba = vec![0; black.len()];
    let mut inverted = Vec::new();
    for (index, ((dark, light), pixel)) in black.as_chunks::<4>().0.iter().zip(white.as_chunks::<4>().0).zip(rgba.as_chunks_mut::<4>().0).enumerate() {
        let differences = [0, 1, 2].map(|c| i16::from(light[c]) - i16::from(dark[c]));
        let min = differences[0].min(differences[1]).min(differences[2]);
        let max = differences[0].max(differences[1]).max(differences[2]);
        if min < 0 || max - min > 1 {
            pixel[3] = 255;
            inverted.push(index);
            continue;
        }
        let alpha = 255 - ((min + max) / 2) as u16;
        if let Some(opacity) = std::num::NonZeroU16::new(alpha) {
            for c in 0..3 {
                pixel[c] = ((u16::from(dark[2 - c]) * 255 + alpha / 2) / opacity).min(255) as u8;
            }
            pixel[3] = alpha as u8;
        }
    }
    let height = rgba.len() / (width * 4);
    for index in inverted {
        let (x, y) = (index % width, index / width);
        let neighbors =
            [x.checked_sub(1).map(|x| (x, y)), (x + 1 < width).then_some((x + 1, y)), y.checked_sub(1).map(|y| (x, y)), (y + 1 < height).then_some((x, y + 1))];
        for (x, y) in neighbors.into_iter().flatten() {
            let start = (y * width + x) * 4;
            if rgba[start + 3] == 0 {
                rgba[start..start + 4].fill(255);
            }
        }
    }
    Some(rgba)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recovers_color_and_converts_an_inverting_caret_to_black_with_a_white_edge() {
        let black = [[0, 0, 128, 0], [0; 4], [255; 4], [0; 4], [0; 4], [255; 4], [0; 4]].concat();
        let white = [[127, 127, 255, 0], [255; 4], [0; 4], [255; 4], [255; 4], [255; 4], [0; 4]].concat();
        let actual = from_black_and_white(7, &black, &white).unwrap();
        assert_eq!(actual, [[255, 0, 0, 128], [255; 4], [0, 0, 0, 255], [255; 4], [0; 4], [255; 4], [0, 0, 0, 255]].concat());
    }
}
