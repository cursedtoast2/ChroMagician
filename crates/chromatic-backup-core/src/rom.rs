use crate::BackupError;
use serde::Serialize;
use sha1::{Digest, Sha1};

/// Header metadata, without claiming that the board supplies the game's RTC.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CartridgeHeader {
    pub title: String,
    pub cartridge_type: u8,
    pub color: bool,
    pub rom_size: u64,
    pub save_size: u64,
    pub rtc_expected: bool,
    /// Checksum declared in the header; not a full-ROM integrity result.
    pub global_checksum: String,
    pub header_checksum: u8,
    pub rom_version: u8,
    /// `FlashGBX` identity over bytes already present in the 1 KiB header read.
    /// This is a catalog key, not a security or full-ROM integrity check.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub header_sha1: Option<String>,
}

/// Use the same title identity for discovery and firmware transfer metadata.
/// Color headers may append a manufacturer code after the 11-byte title.
pub(crate) fn header_title(bytes: &[u8], color: bool) -> String {
    bytes
        .iter()
        .copied()
        .take(if color { 11 } else { 16 })
        .take_while(|byte| *byte != 0)
        .map(|byte| {
            if byte.is_ascii_graphic() || byte == b' ' {
                char::from(byte)
            } else {
                '?'
            }
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

pub(crate) fn inspect_header(data: &[u8]) -> Result<CartridgeHeader, BackupError> {
    validate_header(data)?;
    let color = data[0x143] & 0x80 != 0;
    let title = header_title(&data[0x134..0x144], color);
    let rom_size = match data[0x148] {
        size @ 0..=8 => 32_768_u64 << size,
        0x52 => 72 * 16_384,
        0x53 => 80 * 16_384,
        0x54 => 96 * 16_384,
        _ => return Err(BackupError::InvalidRom("unknown ROM size in header".into())),
    };
    let save_size = if matches!(data[0x147], 0x05 | 0x06) {
        512
    } else {
        match data[0x149] {
            0 => 0,
            1 => 2048,
            2 => 8192,
            3 => 32768,
            4 => 131_072,
            5 => 65536,
            _ => {
                return Err(BackupError::InvalidRom(
                    "unknown save size in header".into(),
                ));
            }
        }
    };
    Ok(CartridgeHeader {
        title,
        cartridge_type: data[0x147],
        color,
        rom_size,
        save_size,
        rtc_expected: matches!(data[0x147], 0x0f | 0x10),
        global_checksum: format!("{:04x}", u16::from_be_bytes([data[0x14e], data[0x14f]])),
        header_checksum: data[0x14d],
        rom_version: data[0x14c],
        header_sha1: data
            .get(..0x180)
            .map(|bytes| hex::encode(Sha1::digest(bytes))),
    })
}

fn validate_header(data: &[u8]) -> Result<(), BackupError> {
    if data.len() < HEADER_SIZE {
        return Err(BackupError::InvalidRom(
            "cartridge header is truncated".into(),
        ));
    }
    if data[0x104..0x134] != NINTENDO_LOGO {
        return Err(BackupError::InvalidRom(
            "invalid Nintendo logo in cartridge header".into(),
        ));
    }
    let actual = data[0x134..0x14d]
        .iter()
        .fold(0_u8, |sum, byte| sum.wrapping_sub(*byte).wrapping_sub(1));
    if actual != data[0x14d] {
        return Err(BackupError::InvalidRom(format!(
            "header checksum {actual:02x} != {:02x}",
            data[0x14d]
        )));
    }
    Ok(())
}

const HEADER_SIZE: usize = 0x150;
const NINTENDO_LOGO: [u8; 48] = [
    0xce, 0xed, 0x66, 0x66, 0xcc, 0x0d, 0x00, 0x0b, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0c, 0x00, 0x0d,
    0x00, 0x08, 0x11, 0x1f, 0x88, 0x89, 0x00, 0x0e, 0xdc, 0xcc, 0x6e, 0xe6, 0xdd, 0xdd, 0xd9, 0x99,
    0xbb, 0xbb, 0x67, 0x63, 0x6e, 0x0e, 0xec, 0xcc, 0xdd, 0xdc, 0x99, 0x9f, 0xbb, 0xb9, 0x33, 0x3e,
];

pub(crate) struct RomValidator {
    header: [u8; HEADER_SIZE],
    length: usize,
    checksum: u16,
}

impl RomValidator {
    pub(crate) const fn new() -> Self {
        Self {
            header: [0; HEADER_SIZE],
            length: 0,
            checksum: 0,
        }
    }

    pub(crate) fn update(&mut self, data: &[u8]) {
        let header_remaining = HEADER_SIZE.saturating_sub(self.length);
        let header_count = header_remaining.min(data.len());
        if header_count != 0 {
            self.header[self.length..self.length + header_count]
                .copy_from_slice(&data[..header_count]);
        }
        for (offset, byte) in data.iter().copied().enumerate() {
            let absolute = self.length + offset;
            if !matches!(absolute, 0x14e | 0x14f) {
                self.checksum = self.checksum.wrapping_add(u16::from(byte));
            }
        }
        self.length += data.len();
    }

    pub(crate) fn validate(self) -> Result<(), BackupError> {
        if self.length < HEADER_SIZE {
            return Err(BackupError::InvalidRom(
                "cartridge header is truncated".into(),
            ));
        }
        validate_header(&self.header)?;
        let expected = u16::from_be_bytes([self.header[0x14e], self.header[0x14f]]);
        if self.checksum != expected {
            return Err(BackupError::InvalidRom(format!(
                "global checksum {:04x} != {expected:04x}",
                self.checksum
            )));
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn valid_rom() -> Vec<u8> {
        let mut rom = vec![0_u8; 32 * 1024];
        rom[0x104..0x134].copy_from_slice(&NINTENDO_LOGO);
        rom[0x134..0x13b].copy_from_slice(b"TESTROM");
        rom[0x14d] = rom[0x134..0x14d].iter().fold(0_u8, |checksum, byte| {
            checksum.wrapping_sub(*byte).wrapping_sub(1)
        });
        let checksum = rom
            .iter()
            .enumerate()
            .filter(|(index, _)| !matches!(index, 0x14e | 0x14f))
            .fold(0_u16, |sum, (_, byte)| sum.wrapping_add(u16::from(*byte)));
        rom[0x14e..0x150].copy_from_slice(&checksum.to_be_bytes());
        rom
    }

    #[test]
    fn validates_incremental_rom() {
        let rom = valid_rom();
        let mut validator = RomValidator::new();
        for chunk in rom.chunks(997) {
            validator.update(chunk);
        }
        validator.validate().unwrap();
    }

    #[test]
    fn rejects_corrupt_rom() {
        let mut rom = valid_rom();
        rom[0x200] ^= 1;
        let mut validator = RomValidator::new();
        validator.update(&rom);
        assert!(matches!(
            validator.validate(),
            Err(BackupError::InvalidRom(_))
        ));
    }

    #[test]
    fn inspection_validates_header_without_claiming_global_integrity_or_physical_rtc() {
        let mut rom = valid_rom();
        rom[0x143] = 0x80;
        rom[0x147] = 0x10;
        rom[0x148] = 6;
        rom[0x149] = 3;
        rom[0x14d] = rom[0x134..0x14d]
            .iter()
            .fold(0_u8, |sum, byte| sum.wrapping_sub(*byte).wrapping_sub(1));
        let header = inspect_header(&rom[..1024]).unwrap();
        assert_eq!(header.title, "TESTROM");
        assert_eq!(header.rom_size, 2 * 1024 * 1024);
        assert_eq!(header.save_size, 32768);
        assert!(header.rtc_expected);
        assert_eq!(
            header.global_checksum,
            format!("{:02x}{:02x}", rom[0x14e], rom[0x14f])
        );
        assert_eq!(header.header_checksum, rom[0x14d]);
        assert_eq!(header.rom_version, rom[0x14c]);
        let hash = header.header_sha1.clone().unwrap();
        assert_eq!(hash, hex::encode(Sha1::digest(&rom[..0x180])));
        rom[0x180] ^= 1;
        assert_eq!(
            inspect_header(&rom).unwrap().header_sha1.as_deref(),
            Some(hash.as_str())
        );
        rom[0x17f] ^= 1;
        assert_ne!(
            inspect_header(&rom).unwrap().header_sha1.as_deref(),
            Some(hash.as_str())
        );
        assert!(inspect_header(&rom[..0x150]).unwrap().header_sha1.is_none());
        assert!(inspect_header(&rom[..256]).is_err());
        rom[0x134] ^= 1;
        assert!(inspect_header(&rom).is_err());
    }
}
