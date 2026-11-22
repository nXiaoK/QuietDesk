//! QuietDeskCore's systematic Cauchy matrix over GF(256), with primitive polynomial 0x11d.
use super::super::PAYLOAD;
use crate::error::{DeskError, Result};
use std::sync::LazyLock;

struct Field {
    products: Box<[[u8; 256]]>,
    inverse: [u8; 256],
}

static FIELD: LazyLock<Field> = LazyLock::new(|| {
    let mut exponent = [0u8; 510];
    let mut logarithm = [0usize; 256];
    let mut value = 1u16;
    for power in 0..255 {
        exponent[power] = value as u8;
        exponent[power + 255] = value as u8;
        logarithm[value as usize] = power;
        value <<= 1;
        if value & 0x100 != 0 {
            value ^= 0x11d;
        }
    }
    let mut products = vec![[0; 256]; 256].into_boxed_slice();
    let mut inverse = [0; 256];
    for a in 1..256 {
        inverse[a] = exponent[255 - logarithm[a]];
        for b in 1..256 {
            products[a][b] = exponent[logarithm[a] + logarithm[b]];
        }
    }
    Field { products, inverse }
});

pub(super) fn coefficient(row: usize, column: usize) -> u8 {
    FIELD.inverse[row ^ (16 + column)]
}

fn add_scaled(destination: &mut [u8], source: &[u8], factor: u8) {
    let products = &FIELD.products[usize::from(factor)];
    for (out, byte) in destination.iter_mut().zip(source) {
        *out ^= products[usize::from(*byte)];
    }
}

pub(super) fn encode<'a>(data: impl Iterator<Item = &'a [u8]>, row: usize) -> Vec<u8> {
    let mut output = vec![0; PAYLOAD];
    for (col, shard) in data.enumerate() {
        add_scaled(&mut output, shard, coefficient(row, col));
    }
    output
}

/// Solves at most four erasures. Short final data fragments have implicit zero padding.
pub(super) fn recover(data: &[Option<&[u8]>], parity: &[Option<Box<[u8]>>; 4]) -> Result<Vec<(usize, Vec<u8>)>> {
    let missing: Vec<_> = data.iter().enumerate().filter_map(|(col, shard)| shard.is_none().then_some(col)).collect();
    let count = missing.len();
    if count == 0 || count > parity.iter().flatten().count() {
        return Ok(Vec::new());
    }
    let mut matrix = [[0u8; 4]; 4];
    let mut rhs = Vec::with_capacity(count);
    for (r, (parity_row, shard)) in parity.iter().enumerate().filter_map(|(i, s)| s.as_ref().map(|s| (i, s))).take(count).enumerate() {
        let mut residual = shard.to_vec();
        for (col, shard) in data.iter().enumerate() {
            if let Some(known) = shard {
                add_scaled(&mut residual, known, coefficient(parity_row, col));
            }
        }
        for (j, col) in missing.iter().enumerate() {
            matrix[r][j] = coefficient(parity_row, *col);
        }
        rhs.push(residual);
    }
    // Row operations on the payloads apply the inverse erasure matrix without forming an extra matrix.
    for col in 0..count {
        let pivot = (col..count).find(|&r| matrix[r][col] != 0).ok_or_else(|| DeskError::invalid("纠错子矩阵不可逆"))?;
        matrix.swap(col, pivot);
        rhs.swap(col, pivot);
        let scale = &FIELD.products[usize::from(FIELD.inverse[usize::from(matrix[col][col])])];
        for value in &mut matrix[col][..count] {
            *value = scale[usize::from(*value)];
        }
        for byte in &mut rhs[col] {
            *byte = scale[usize::from(*byte)];
        }
        let pivot_coefficients = matrix[col];
        let (above, from_pivot) = rhs.split_at_mut(col);
        let (pivot_payload, below) = from_pivot.split_first_mut().expect("pivot inside the validated erasure count");
        for (r, out) in above.iter_mut().enumerate().chain((col + 1..count).zip(below.iter_mut())) {
            let factor = matrix[r][col];
            if factor != 0 {
                add_scaled(&mut matrix[r][..count], &pivot_coefficients, factor);
                add_scaled(out, pivot_payload, factor);
            }
        }
    }
    Ok(missing.into_iter().zip(rhs).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mac_coefficients_and_nonconsecutive_parity_rows_recover_the_missing_columns() {
        let expected = include_bytes!("../vectors/cauchy.bin");
        let actual: Vec<_> = (0..4).flat_map(|row| (0..16).map(move |col| coefficient(row, col))).collect();
        assert_eq!(&actual[..], &expected[..]);
        let inputs: Vec<Vec<u8>> = (0..10).map(|col| (0..if col == 9 { 73 } else { PAYLOAD }).map(|i| (37 * col + 13 * i + 7) as u8).collect()).collect();
        let mut rows: [Option<Box<[u8]>>; 4] = std::array::from_fn(|i| Some(encode(inputs.iter().map(Vec::as_slice), i).into_boxed_slice()));
        let all: Vec<_> = inputs.iter().map(|x| Some(x.as_slice())).collect();
        for bits in 1..1_024u32 {
            let missing = bits.count_ones();
            if !(1..=4).contains(&missing) {
                continue;
            }
            if missing != 3 && bits.trailing_zeros() > 0 {
                continue;
            }
            let mut data = all.clone();
            for (col, slot) in data.iter_mut().enumerate() {
                if bits & (1 << col) != 0 {
                    *slot = None;
                }
            }
            let omit = if missing == 3 { rows[1].take() } else { None };
            let repaired = recover(&data, &rows).unwrap();
            assert_eq!(repaired.len(), missing as usize);
            for (index, shard) in repaired {
                assert_eq!(shard[..inputs[index].len()], inputs[index]);
                assert!(shard[inputs[index].len()..].iter().all(|&x| x == 0));
            }
            if omit.is_some() {
                rows[1] = omit;
            }
        }
    }
}
