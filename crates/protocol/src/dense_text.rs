pub fn encode(bytes: &[u8]) -> String {
    let mut output = String::new();
    let mut accumulator = 0u32;
    let mut bits = 0u32;

    for byte in bytes {
        accumulator = (accumulator << 8) | u32::from(*byte);
        bits += 8;
        while bits >= 15 {
            bits -= 15;
            output.push(character((accumulator >> bits) & 0x7fff));
        }
        accumulator &= (1 << bits) - 1;
    }

    if bits > 7 {
        output.push(character((accumulator << (15 - bits)) & 0x7fff));
    } else if bits > 0 {
        output.push(char::from_u32(0xc040 + ((accumulator << (7 - bits)) & 0x7f)).unwrap());
    }

    output
}

pub fn decode(text: &str) -> Option<Vec<u8>> {
    let scalars: Vec<char> = text.chars().collect();
    let mut output = Vec::with_capacity(scalars.len() * 15 / 8);
    let mut accumulator = 0u32;
    let mut bits = 0u32;

    for (index, scalar) in scalars.iter().enumerate() {
        let value = match *scalar as u32 {
            0x3400..=0x4dbf => *scalar as u32 - 0x3400,
            0x4e00..=0x9fff => *scalar as u32 - 0x4e00 + 6592,
            0xac00..=0xc03f => *scalar as u32 - 0xac00 + 27584,
            0xc040..=0xc0bf if index + 1 == scalars.len() => {
                accumulator = (accumulator << 7) | (*scalar as u32 - 0xc040);
                bits += 7;
                while bits >= 8 {
                    bits -= 8;
                    output.push((accumulator >> bits) as u8);
                }
                accumulator &= (1 << bits) - 1;
                continue;
            }
            _ => return None,
        };

        accumulator = (accumulator << 15) | value;
        bits += 15;
        while bits >= 8 {
            bits -= 8;
            output.push((accumulator >> bits) as u8);
        }
        accumulator &= (1 << bits) - 1;
    }

    Some(output)
}

fn character(value: u32) -> char {
    let scalar = match value {
        0..=6591 => 0x3400 + value,
        6592..=27583 => 0x4e00 + value - 6592,
        _ => 0xac00 + value - 27584,
    };
    char::from_u32(scalar).unwrap()
}
