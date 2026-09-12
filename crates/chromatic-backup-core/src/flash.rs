//! `FlashGBX` profile execution over the existing MCU cartridge bus.
use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::write_upload;
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serialport::SerialPort;

use crate::{
    BackupError, EVENT_SCHEMA_VERSION, field, find_subslice, open_chromatic, parse_decimal,
    parse_hex_u32, read_exact_until, read_line_until, rom::RomValidator,
};

pub const FLASH_PROFILES: &[&str] = &["modretro"];
const BLOCK: usize = 1024;
const MBC5: u8 = 0x1b;

#[derive(Debug, Clone)]
pub struct RomWriteRequest {
    pub port: Option<String>,
    pub rom_path: PathBuf,
    pub profile: String,
    pub timeout: Duration,
    pub boot_wait: Duration,
}

impl Default for RomWriteRequest {
    fn default() -> Self {
        Self {
            port: None,
            rom_path: PathBuf::new(),
            profile: "modretro".into(),
            timeout: Duration::from_mins(5),
            boot_wait: Duration::from_secs(3),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum RomWriteEvent {
    SessionStarted {
        schema_version: u8,
    },
    DeviceConnected {
        port: String,
    },
    FlashDetected {
        profile: String,
        chip_id: String,
        capacity: usize,
    },
    RomValidated {
        path: PathBuf,
        size: usize,
        crc32: String,
    },
    EraseStarted {
        capacity: usize,
    },
    Progress {
        phase: String,
        completed: usize,
        total: usize,
    },
    Complete {
        operation: String,
        elapsed_ms: u128,
    },
}

#[derive(Debug, Clone)]
pub struct RomWriteResult {
    pub chip_id: Vec<u8>,
    pub rom_path: PathBuf,
    pub elapsed: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct InspectedCartridge {
    #[serde(flatten)]
    pub header: crate::CartridgeHeader,
    pub rom_writable: bool,
    /// Physical capacity of an identified flash chip, independent of the ROM header.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cart_size: Option<usize>,
}

#[derive(Deserialize)]
struct Profile {
    flash_ids: Vec<Vec<u8>>,
    flash_size: usize,
    chip_erase_timeout: u64,
    commands: Commands,
    #[serde(default)]
    buffered: bool,
    #[serde(default)]
    wide_buffer: bool,
}

#[derive(Deserialize)]
struct Commands {
    reset: Vec<(u16, u8)>,
    read_identifier: Vec<(u16, u8)>,
    chip_erase: Vec<(u16, u8)>,
    single_write: Vec<(serde_json::Value, serde_json::Value)>,
}

fn profile(name: &str) -> Result<Profile, BackupError> {
    if name != "modretro" {
        return Err(BackupError::Flash(format!(
            "unsupported profile {name:?}; supported: modretro"
        )));
    }
    serde_json::from_str(include_str!("../profiles/modretro.json"))
        .map_err(|error| BackupError::Flash(format!("invalid bundled profile: {error}")))
}

fn profiles(name: &str) -> Result<(Profile, Profile), BackupError> {
    let mut base = profile(name)?;
    let issi: Profile =
        serde_json::from_str(include_str!("../profiles/modretro-is29gl032.json"))
            .map_err(|error| BackupError::Flash(format!("invalid IS29 profile: {error}")))?;
    base.flash_ids.extend(issi.flash_ids.clone());
    Ok((base, issi))
}

impl Profile {
    fn program_prefix(&self) -> Result<Vec<(u16, u8)>, BackupError> {
        let commands = &self.commands.single_write;
        if commands.last() != Some(&(serde_json::json!("PA"), serde_json::json!("PD"))) {
            return Err(BackupError::Flash(
                "unsupported profile program sequence".into(),
            ));
        }
        commands[..commands.len() - 1]
            .iter()
            .map(|(address, value)| {
                let address = address.as_u64().and_then(|v| u16::try_from(v).ok());
                let value = value.as_u64().and_then(|v| u8::try_from(v).ok());
                address
                    .zip(value)
                    .ok_or_else(|| BackupError::Flash("invalid program prefix".into()))
            })
            .collect()
    }
}

fn validate_rom(rom: &[u8], capacity: usize) -> Result<(), BackupError> {
    let mut validator = RomValidator::new();
    validator.update(rom);
    validator.validate()?;
    let declared = 32_768_usize
        .checked_shl(u32::from(rom[0x148]))
        .filter(|size| *size <= capacity);
    if declared != Some(rom.len()) {
        return Err(BackupError::InvalidRom(format!(
            "file length must match its ROM-size header and fit the {capacity}-byte cartridge"
        )));
    }
    Ok(())
}

trait Cart {
    fn read(&mut self, address: u16) -> Result<Vec<u8>, BackupError>;
    fn writes(&mut self, commands: &[(u16, u8)]) -> Result<(), BackupError>;
    fn bank(&mut self, bank: usize) -> Result<u16, BackupError>;
    fn read_range(&mut self, address: u16, blocks: u8) -> Result<Vec<u8>, BackupError> {
        let mut data = Vec::new();
        for index in 0..blocks {
            data.extend(self.read(address + u16::from(index) * 1024)?);
        }
        Ok(data)
    }
    fn program(&mut self, address: u16, mode: u8, data: &[u8]) -> Result<(), BackupError>;
}

struct Connection {
    port: Box<dyn SerialPort>,
    sequence: u32,
    deadline: Instant,
    healthy: bool,
}

impl Connection {
    fn open(
        request: &RomWriteRequest,
        event: &mut impl FnMut(RomWriteEvent),
    ) -> Result<Self, BackupError> {
        let (name, port) = open_chromatic(request.port.as_deref(), request.boot_wait)?;
        event(RomWriteEvent::DeviceConnected { port: name });
        let mut connection = Self {
            port,
            sequence: 0,
            deadline: Instant::now() + request.timeout,
            healthy: false,
        };
        connection.start_session(request.timeout.min(Duration::from_secs(10)))?;
        connection.deadline = Instant::now() + request.timeout;
        Ok(connection)
    }

    fn start_session(&mut self, timeout: Duration) -> Result<(), BackupError> {
        self.sequence = 0;
        self.healthy = false;
        self.deadline = Instant::now() + timeout;
        write!(self.port, "\rpcflash --mapper {MBC5:02x}\r")?;
        self.port.flush()?;
        let (record, fields) = self.record(self.deadline)?;
        if record != "READY"
            || field(&fields, "protocol")? != "2"
            || field(&fields, "bulk")? != "3"
            || field(&fields, "block")? != "1024"
        {
            return Err(BackupError::Protocol(
                "unsupported PCFLASH firmware handshake".into(),
            ));
        }
        self.healthy = true;
        Ok(())
    }

    fn record(
        &mut self,
        deadline: Instant,
    ) -> Result<(String, BTreeMap<String, String>), BackupError> {
        while let Some(line) = read_line_until(&mut *self.port, deadline)? {
            let Some(start) = find_subslice(&line, b"PCFLASH ") else {
                continue;
            };
            let text = std::str::from_utf8(&line[start..])
                .map_err(|_| BackupError::Protocol("non-UTF8 flash response".into()))?;
            let mut words = text.split_ascii_whitespace().skip(1);
            let record = words
                .next()
                .ok_or_else(|| BackupError::Protocol("missing flash record".into()))?;
            let mut fields = BTreeMap::new();
            for word in words {
                let (key, value) = word
                    .split_once('=')
                    .ok_or_else(|| BackupError::Protocol("malformed flash field".into()))?;
                if fields.insert(key.to_owned(), value.to_owned()).is_some() {
                    return Err(BackupError::Protocol("duplicate flash field".into()));
                }
            }
            if record == "FAIL" {
                return Err(BackupError::Device(
                    fields.get("error").cloned().unwrap_or_default(),
                ));
            }
            return Ok((record.to_owned(), fields));
        }
        Err(BackupError::Timeout)
    }

    fn exchange(&mut self, payload: &[u8], expected: usize) -> Result<Vec<u8>, BackupError> {
        if Instant::now() >= self.deadline {
            return Err(BackupError::Timeout);
        }
        self.healthy = false;
        write_upload(&mut *self.port, &frame(self.sequence, payload)?)?;
        let direct_size = if payload.first() == Some(&5) {
            usize::from(payload[3]) * BLOCK
        } else {
            0
        };
        let direct = if direct_size != 0 {
            let (record, fields) = self.record(self.deadline)?;
            if record != "BULK"
                || parse_decimal(field(&fields, "size")?, "bulk size")? != direct_size as u64
            {
                return Err(BackupError::Protocol("unexpected bulk header".into()));
            }
            Some(read_exact_until(
                &mut *self.port,
                direct_size,
                self.deadline,
            )?)
        } else {
            None
        };
        let (record, fields) = self.record(self.deadline)?;
        if record != "OK"
            || parse_decimal(field(&fields, "seq")?, "flash sequence")? != u64::from(self.sequence)
            || parse_decimal(field(&fields, "size")?, "flash reply size")? != expected as u64
        {
            return Err(BackupError::Protocol(
                "unexpected flash response sequence/size".into(),
            ));
        }
        let data = field(&fields, "data")?;
        let bytes = if data == "-" {
            Vec::new()
        } else {
            base64::engine::general_purpose::STANDARD
                .decode(data)
                .map_err(|_| BackupError::Protocol("invalid flash response base64".into()))?
        };
        if bytes.len() != expected
            || crc32fast::hash(&bytes)
                != parse_hex_u32(field(&fields, "crc")?, "flash response CRC")?
        {
            return Err(BackupError::Protocol(
                "flash response length/CRC mismatch".into(),
            ));
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| BackupError::Protocol("flash sequence overflow".into()))?;
        if let Some(direct) = direct {
            if bytes.len() != 4
                || crc32fast::hash(&direct)
                    != u32::from_le_bytes(bytes[..4].try_into().expect("CRC length"))
            {
                return Err(BackupError::Protocol("direct bulk CRC mismatch".into()));
            }
            self.healthy = true;
            return Ok(direct);
        }
        self.healthy = true;
        Ok(bytes)
    }

    fn finish(&mut self) -> Result<(), BackupError> {
        self.exchange(&[0], 0)?;
        self.healthy = false;
        let (record, _) = self.record(self.deadline)?;
        if record != "PASS" {
            return Err(BackupError::Protocol(
                "flash session omitted final PASS".into(),
            ));
        }
        Ok(())
    }
}

pub(crate) fn frame(sequence: u32, payload: &[u8]) -> Result<Vec<u8>, BackupError> {
    if payload.is_empty() || payload.len() > 1536 {
        return Err(BackupError::Protocol("invalid flash request size".into()));
    }
    let mut result = b"CF01".to_vec();
    result.extend(sequence.to_le_bytes());
    result.extend(
        u32::try_from(payload.len())
            .expect("bounded payload")
            .to_le_bytes(),
    );
    result.extend(crc32fast::hash(payload).to_le_bytes());
    result.extend(payload);
    Ok(result)
}

/// Read only the first existing QSPI block for a desktop cartridge overview.
/// No flash identification, erase, or programming commands are issued.
///
/// # Errors
/// Returns transport, session cleanup, or cartridge-header validation errors.
pub fn inspect_cartridge(
    request: &RomWriteRequest,
    mut event: impl FnMut(RomWriteEvent),
) -> Result<crate::CartridgeHeader, BackupError> {
    event(RomWriteEvent::SessionStarted {
        schema_version: EVENT_SCHEMA_VERSION,
    });
    let mut cart = Connection::open(request, &mut event)?;
    let header = cart
        .read(0)
        .and_then(|bytes| crate::rom::inspect_header(&bytes));
    let cleanup = if cart.healthy { cart.finish() } else { Ok(()) };
    let header = header?;
    cleanup?;
    Ok(header)
}

/// Watch header changes using the existing read command and one open USB port.
/// Each sample finishes its maintenance session so the device menu remains usable.
/// New insertions reuse the writer's chip-ID/CFI probe to report writability.
/// `None` means no readable game (including when PC mode is not enabled).
///
/// # Errors
/// Returns USB disconnection or transport errors. No erase/program commands run.
pub fn watch_cartridge(
    request: &RomWriteRequest,
    stopped: impl Fn() -> bool,
    event: impl FnMut(Option<InspectedCartridge>),
) -> Result<(), BackupError> {
    let (_, port) = open_chromatic(request.port.as_deref(), request.boot_wait)?;
    let connection = Connection {
        port,
        sequence: 0,
        deadline: Instant::now(),
        healthy: false,
    };
    watch_connection(connection, stopped, event)
}

fn watch_connection(
    connection: Connection,
    stopped: impl Fn() -> bool,
    event: impl FnMut(Option<InspectedCartridge>),
) -> Result<(), BackupError> {
    watch_connection_with_sd(
        connection,
        stopped,
        event,
        |_| Ok(()),
        |_| Ok((true, false)),
        |_| Ok(()),
    )
}

/// Watch cartridge and SD insertion using one USB connection.
/// # Errors
/// Returns transport errors after USB disconnection.
pub fn watch_device(
    request: &RomWriteRequest,
    stopped: impl Fn() -> bool,
    event: impl FnMut(Option<InspectedCartridge>),
    sd_event: impl FnMut(crate::SdStatus),
    status_event: impl FnMut(crate::DeviceStatus),
    requests: impl FnMut(&mut dyn SerialPort) -> Result<(), BackupError>,
) -> Result<(), BackupError> {
    let (_, port) = open_chromatic(request.port.as_deref(), request.boot_wait)?;
    let connection = Connection {
        port,
        sequence: 0,
        deadline: Instant::now(),
        healthy: false,
    };
    watch_device_connection(connection, stopped, event, sd_event, status_event, requests)
}

fn watch_device_connection(
    connection: Connection,
    stopped: impl Fn() -> bool,
    event: impl FnMut(Option<InspectedCartridge>),
    mut sd_event: impl FnMut(crate::SdStatus),
    mut status_event: impl FnMut(crate::DeviceStatus),
    requests: impl FnMut(&mut dyn SerialPort) -> Result<(), BackupError>,
) -> Result<(), BackupError> {
    let mut next = Instant::now();
    let mut previous = None;
    let mut previous_status = None;
    let refresh_sd = std::cell::Cell::new(true);
    watch_connection_with_sd(
        connection,
        stopped,
        event,
        |port| {
            let refresh = refresh_sd.replace(false);
            if !refresh && Instant::now() < next {
                return Ok(());
            }
            let present = match crate::sd::status_on_port(port) {
                Ok(present) => present,
                Err(error @ (BackupError::Io(_) | BackupError::Serial(_))) => return Err(error),
                Err(error) => crate::SdStatus {
                    present: false,
                    error: Some(error.to_string()),
                },
            };
            if refresh || previous.as_ref() != Some(&present) {
                sd_event(present.clone());
                previous = Some(present);
            }
            next = Instant::now() + Duration::from_secs(5);
            Ok(())
        },
        |port| {
            let sample = crate::firmware::device_status(port)?;
            let status = if sample.enabled.is_some() {
                sample
            } else {
                previous_status.unwrap_or_default()
            };
            if previous_status.map(|value: crate::DeviceStatus| value.enabled)
                != Some(status.enabled)
            {
                refresh_sd.set(true);
            }
            if previous_status != Some(status) {
                status_event(status);
                previous_status = Some(status);
            }
            Ok((
                status.enabled == Some(true) && status.cartridge_present != Some(false),
                status.enabled == Some(true),
            ))
        },
        requests,
    )
}

fn watch_connection_with_sd(
    mut connection: Connection,
    stopped: impl Fn() -> bool,
    mut event: impl FnMut(Option<InspectedCartridge>),
    mut sample_sd: impl FnMut(&mut dyn SerialPort) -> Result<(), BackupError>,
    mut sample_status: impl FnMut(&mut dyn SerialPort) -> Result<(bool, bool), BackupError>,
    mut requests: impl FnMut(&mut dyn SerialPort) -> Result<(), BackupError>,
) -> Result<(), BackupError> {
    let mut previous: Option<Option<InspectedCartridge>> = None;
    while !stopped() {
        requests(&mut *connection.port)?;
        if stopped() {
            return Ok(());
        }
        let (read_cart, read_sd) = sample_status(&mut *connection.port)?;
        let sample = if read_cart {
            connection
                .start_session(Duration::from_millis(750))
                .and_then(|()| {
                    connection.deadline = Instant::now() + Duration::from_secs(2);
                    connection.read(0)
                })
                .and_then(|bytes| crate::rom::inspect_header(&bytes))
                .and_then(|header| {
                    if let Some(Some(known)) = &previous
                        && known.header == header
                    {
                        return Ok(known.clone());
                    }
                    connection.deadline = Instant::now() + Duration::from_secs(5);
                    let (mut profile, issi) = profiles("modretro")?;
                    let cart_size = match select_profile(&mut connection, &mut profile, issi) {
                        Ok(_) => Some(profile.flash_size),
                        Err(BackupError::Flash(_)) => None,
                        Err(error) => return Err(error),
                    };
                    Ok(InspectedCartridge {
                        header,
                        rom_writable: cart_size.is_some(),
                        cart_size,
                    })
                })
        } else {
            Err(BackupError::Device("Cartridge access unavailable".into()))
        };
        let cleanup = if connection.healthy {
            connection.finish()
        } else {
            Ok(())
        };
        let current = match cleanup.and(sample) {
            Ok(header) => Some(header),
            Err(error @ (BackupError::Io(_) | BackupError::Serial(_))) => return Err(error),
            Err(_) => None,
        };
        if previous.as_ref() != Some(&current) {
            event(current.clone());
            previous = Some(current);
        }
        if !stopped() && read_sd {
            sample_sd(&mut *connection.port)?;
        }
        for _ in 0..10 {
            if stopped() {
                return Ok(());
            }
            requests(&mut *connection.port)?;
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    Ok(())
}

fn append_writes(payload: &mut Vec<u8>, commands: &[(u16, u8)]) {
    for (address, value) in commands {
        payload.extend(address.to_le_bytes());
        payload.push(*value);
    }
}

impl Cart for Connection {
    fn read(&mut self, address: u16) -> Result<Vec<u8>, BackupError> {
        let mut payload = vec![1];
        payload.extend(address.to_le_bytes());
        self.exchange(&payload, BLOCK)
    }
    fn writes(&mut self, commands: &[(u16, u8)]) -> Result<(), BackupError> {
        let mut payload = vec![2];
        append_writes(&mut payload, commands);
        self.exchange(&payload, 0).map(|_| ())
    }
    fn bank(&mut self, bank: usize) -> Result<u16, BackupError> {
        let bank = u32::try_from(bank).map_err(|_| BackupError::Flash("bank overflow".into()))?;
        let mut payload = vec![3];
        payload.extend(bank.to_le_bytes());
        let bytes = self.exchange(&payload, 2)?;
        let window = u16::from_le_bytes([bytes[0], bytes[1]]);
        if window != 0x4000 {
            return Err(BackupError::Protocol("unexpected MBC5 bank window".into()));
        }
        Ok(window)
    }
    fn read_range(&mut self, address: u16, blocks: u8) -> Result<Vec<u8>, BackupError> {
        if blocks == 0 || blocks > 16 {
            return Err(BackupError::Protocol("invalid bulk range".into()));
        }
        let mut payload = vec![5];
        payload.extend(address.to_le_bytes());
        payload.push(blocks);
        self.exchange(&payload, 4)
    }
    fn program(&mut self, address: u16, mode: u8, data: &[u8]) -> Result<(), BackupError> {
        if !matches!(mode, 0x82 | 0x83 | 0x85) || data.len() != BLOCK {
            return Err(BackupError::Protocol("invalid program block".into()));
        }
        let mut payload = vec![4];
        payload.extend(address.to_le_bytes());
        payload.push(mode);
        payload.extend(data);
        self.exchange(&payload, 0).map(|_| ())
    }
}

fn identify(cart: &mut impl Cart, profile: &Profile) -> Result<Vec<u8>, BackupError> {
    let window = cart.bank(0)?;
    cart.writes(&profile.commands.reset)?;
    let original = cart.read(0)?;
    if cart.read(window)? != original {
        return Err(BackupError::Flash(
            "MBC5 bank zero does not map into the programming window; nothing erased".into(),
        ));
    }
    cart.writes(&profile.commands.read_identifier)?;
    let id = cart.read(0)?;
    cart.writes(&profile.commands.reset)?;
    profile.flash_ids.iter().find(|expected| {
        id.starts_with(expected) && !original.starts_with(expected)
    }).cloned().ok_or_else(|| BackupError::Flash(format!(
        "unsupported cartridge: flash ID {}; expected a supported ModRetro flash chip; nothing erased",
        hex::encode(&id[..id.len().min(4)])
    )))
}

fn validate_cfi(cfi: &[u8], capacity: usize) -> Result<(), BackupError> {
    if cfi.len() < 0x58
        || [cfi[0x20], cfi[0x22], cfi[0x24]] != *b"QRY"
        || cfi[0x26] != 2
        || cfi[0x28] != 0
        || 1_usize.checked_shl(u32::from(cfi[0x4e])) != Some(capacity)
        || cfi[0x54] < 5
        || cfi[0x54] > 10
        || cfi[0x56] != 0
        || cfi[0x40] == 0
        || cfi[0x40] > 16
        || cfi[0x48] > 16
        || u64::checked_shl(1, u32::from(cfi[0x44]) + u32::from(cfi[0x4c])).is_none()
        || 1_u32
            .checked_shl(u32::from(cfi[0x40]) + u32::from(cfi[0x48]))
            .is_none_or(|us| us > 100_000)
    {
        return Err(BackupError::Flash(
            "CFI does not confirm supported AMD capacity/buffer/timing; nothing erased".into(),
        ));
    }
    Ok(())
}

fn select_profile(
    cart: &mut impl Cart,
    profile: &mut Profile,
    issi: Profile,
) -> Result<Vec<u8>, BackupError> {
    let chip_id = identify(cart, profile)?;
    if issi.flash_ids.contains(&chip_id) {
        *profile = issi;
        profile.buffered = true;
        cart.writes(&[(0xaa, 0x98)])?;
        let cfi = cart.read(0)?;
        cart.writes(&profile.commands.reset)?;
        validate_cfi(&cfi, profile.flash_size)?;
        profile.wide_buffer = cfi[0x54] >= 8;
        if cfi[0x44] != 0 {
            profile.chip_erase_timeout =
                (1_u64 << (u32::from(cfi[0x44]) + u32::from(cfi[0x4c]))).div_ceil(1000);
        }
    }
    Ok(chip_id)
}

fn address(cart: &mut impl Cart, offset: usize, window: &mut u16) -> Result<u16, BackupError> {
    if offset.is_multiple_of(0x4000) {
        *window = cart.bank(offset / 0x4000)?;
    }
    Ok(*window + u16::try_from(offset % 0x4000).expect("bank offset"))
}

fn progress(event: &mut impl FnMut(RomWriteEvent), phase: &str, completed: usize, total: usize) {
    event(RomWriteEvent::Progress {
        phase: phase.into(),
        completed,
        total,
    });
}

fn program_rom(
    cart: &mut impl Cart,
    profile: &Profile,
    rom: &[u8],
    event: &mut impl FnMut(RomWriteEvent),
) -> Result<(), BackupError> {
    if profile.program_prefix()? != [(0xaaa, 0xaa), (0x555, 0x55), (0xaaa, 0xa0)] {
        return Err(BackupError::Flash(
            "profile does not match the staged AMD writer".into(),
        ));
    }
    let mode = if profile.wide_buffer {
        0x85
    } else if profile.buffered {
        0x83
    } else {
        0x82
    };
    event(RomWriteEvent::EraseStarted {
        capacity: profile.flash_size,
    });
    cart.writes(&profile.commands.chip_erase)?;
    let deadline = Instant::now() + Duration::from_secs(profile.chip_erase_timeout);
    loop {
        let data = cart.read(0)?;
        if data.iter().all(|byte| *byte == 0xff) {
            break;
        }
        if Instant::now() >= deadline {
            return Err(BackupError::Flash("chip erase timed out".into()));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut window = 0;
    for (index, block) in rom.chunks(BLOCK).enumerate() {
        let offset = index * BLOCK;
        let address = address(cart, offset, &mut window)?;
        if block.iter().any(|byte| *byte != 0xff) {
            cart.program(address, mode, block)?;
        }
        progress(event, "program", offset + BLOCK, rom.len());
    }
    for offset in (0..profile.flash_size).step_by(0x4000) {
        let address = address(cart, offset, &mut window)?;
        let actual = cart.read_range(address, 16)?;
        let matches = if offset < rom.len() {
            actual == rom[offset..offset + 0x4000]
        } else {
            actual.iter().all(|byte| *byte == 0xff)
        };
        if !matches {
            return Err(BackupError::Flash(format!(
                "final ROM/tail verification failed at 0x{offset:x}"
            )));
        }
        progress(event, "verify", offset + 0x4000, profile.flash_size);
    }
    Ok(())
}

/// Identify a supported flash chip without erasing or programming it.
///
/// # Errors
/// Returns an error for unsupported chips, firmware, or transport failures.
pub fn probe_flash(
    request: &RomWriteRequest,
    event: impl FnMut(RomWriteEvent),
) -> Result<RomWriteResult, BackupError> {
    run(request, false, event)
}

/// Erase, program, and verify a ROM using the bundled `FlashGBX` `ModRetro` profile.
/// The caller must obtain authorization to overwrite the cartridge ROM.
/// Save RAM/RTC import remains a separate operation.
///
/// # Errors
/// Returns an error for invalid ROMs, unsupported chips, or any transfer,
/// programming, or verification failure. Erasure/programming is not atomic.
pub fn write_rom(
    request: &RomWriteRequest,
    event: impl FnMut(RomWriteEvent),
) -> Result<RomWriteResult, BackupError> {
    run(request, true, event)
}

fn run(
    request: &RomWriteRequest,
    write: bool,
    mut event: impl FnMut(RomWriteEvent),
) -> Result<RomWriteResult, BackupError> {
    event(RomWriteEvent::SessionStarted {
        schema_version: EVENT_SCHEMA_VERSION,
    });
    let (mut profile, issi) = profiles(&request.profile)?;
    let rom = if write {
        let metadata = std::fs::metadata(&request.rom_path)?;
        if metadata.len() > issi.flash_size as u64 {
            return Err(BackupError::InvalidRom(
                "ROM exceeds the supported 4 MiB capacity".into(),
            ));
        }
        let bytes = std::fs::read(&request.rom_path)?;
        validate_rom(&bytes, issi.flash_size)?;
        event(RomWriteEvent::RomValidated {
            path: request.rom_path.clone(),
            size: bytes.len(),
            crc32: format!("{:08x}", crc32fast::hash(&bytes)),
        });
        bytes
    } else {
        Vec::new()
    };
    let started = Instant::now();
    let mut cart = Connection::open(request, &mut event)?;
    let operation: Result<Vec<u8>, BackupError> = (|| {
        let chip_id = select_profile(&mut cart, &mut profile, issi)?;
        if write && rom.len() > profile.flash_size {
            return Err(BackupError::InvalidRom(format!(
                "ROM exceeds the detected {}-byte cartridge",
                profile.flash_size
            )));
        }
        event(RomWriteEvent::FlashDetected {
            profile: request.profile.clone(),
            chip_id: hex::encode(&chip_id),
            capacity: profile.flash_size,
        });
        if write {
            program_rom(&mut cart, &profile, &rom, &mut event)?;
        }
        Ok(chip_id)
    })();
    let cleanup = if cart.healthy {
        cart.deadline = cart.deadline.max(Instant::now() + Duration::from_secs(5));
        cart.writes(&profile.commands.reset)
            .and_then(|()| cart.finish())
    } else {
        Ok(())
    };
    let chip_id = operation?;
    cleanup?;
    let elapsed = started.elapsed();
    event(RomWriteEvent::Complete {
        operation: if write { "write_rom" } else { "probe_flash" }.into(),
        elapsed_ms: elapsed.as_millis(),
    });
    Ok(RomWriteResult {
        chip_id,
        rom_path: request.rom_path.clone(),
        elapsed,
    })
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    #[test]
    fn stock_console_stays_unknown_until_a_real_custom_status_reply() {
        use std::cell::Cell;
        use std::io::Read as _;
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_baud_rate(115_200).unwrap();
        client.set_timeout(Duration::from_millis(50)).unwrap();
        device.set_timeout(Duration::from_secs(4)).unwrap();
        let peer = std::thread::spawn(move || {
            for reply in [
                b"pcstatus\r\nUnrecognized command\r\n".as_slice(),
                b"PCSTATUS enabled=0 cartridge=-1\r\n".as_slice(),
            ] {
                let mut command = [0; 11];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\x15\rpcstatus\r");
                device.write_all(reply).unwrap();
            }
            std::thread::sleep(Duration::from_millis(100));
        });
        let confirmed = Cell::new(false);
        let mut modes = Vec::new();
        watch_device_connection(
            Connection {
                port: Box::new(client),
                sequence: 0,
                deadline: Instant::now(),
                healthy: false,
            },
            || confirmed.get(),
            |cart| assert!(cart.is_none()),
            |_| panic!("Do not issue SD commands without confirmed PC mode"),
            |status| {
                confirmed.set(status.enabled == Some(false));
                modes.push(status.enabled);
            },
            |_| Ok(()),
        )
        .unwrap();
        peer.join().unwrap();
        assert_eq!(modes, [None, Some(false)]);
    }

    #[cfg(unix)]
    #[test]
    fn sleeping_mcu_keeps_confirmed_mode_then_detects_enable_without_reopening() {
        use std::cell::Cell;
        use std::io::Read as _;
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_baud_rate(115_200).unwrap();
        client.set_timeout(Duration::from_millis(50)).unwrap();
        device.set_timeout(Duration::from_secs(4)).unwrap();
        let peer = std::thread::spawn(move || {
            for poll in 0..5 {
                let mut command = [0; 11];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\x15\rpcstatus\r");
                match poll {
                    0 => device
                        .write_all(b"PCSTATUS enabled=0 cartridge=-1\r\n")
                        .unwrap(),
                    4 => device
                        .write_all(b"PCSTATUS enabled=1 cartridge=0\r\n")
                        .unwrap(),
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        });
        let enabled = Cell::new(false);
        let mut modes = Vec::new();
        watch_device_connection(
            Connection {
                port: Box::new(client),
                sequence: 0,
                deadline: Instant::now(),
                healthy: false,
            },
            || enabled.get(),
            |cart| assert!(cart.is_none()),
            |_| panic!("must not scan SD while the confirmed mode is off"),
            |status| {
                enabled.set(status.enabled == Some(true));
                modes.push(status);
            },
            |_| Ok(()),
        )
        .unwrap();
        peer.join().unwrap();
        assert_eq!(
            modes,
            vec![
                crate::DeviceStatus {
                    enabled: Some(false),
                    cartridge_present: None
                },
                crate::DeviceStatus {
                    enabled: Some(true),
                    cartridge_present: Some(false)
                },
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn mode_toggle_republishes_sd_and_missing_cart_never_opens_programmer() {
        use super::*;
        use std::cell::Cell;
        use std::io::Read as _;
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(50)).unwrap();
        device.set_timeout(Duration::from_secs(4)).unwrap();
        let peer = std::thread::spawn(move || {
            for enabled in [true, false, true] {
                let mut command = [0; 11];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\x15\rpcstatus\r");
                writeln!(device, "PCSTATUS enabled={} cartridge=0", u8::from(enabled)).unwrap();
                if !enabled {
                    continue;
                }
                let mut command = [0; 6];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\rpcsd\r");
                device
                    .write_all(b"PCSD READY protocol=1 block=1024\n")
                    .unwrap();
                let mut packet = [0; 17];
                device.read_exact(&mut packet).unwrap();
                assert_eq!(packet.to_vec(), frame(0, &[1]).unwrap());
                device
                    .write_all(b"PCSD STATUS present=1 error=ESP_OK\nPCSD OK seq=0\n")
                    .unwrap();
                device.read_exact(&mut packet).unwrap();
                assert_eq!(packet.to_vec(), frame(1, &[0]).unwrap());
                device
                    .write_all(b"PCSD OK seq=1\nPCSD PASS error=ESP_OK\n")
                    .unwrap();
            }
            std::thread::sleep(Duration::from_millis(100));
        });
        let count = Cell::new(0);
        let mut modes = Vec::new();
        watch_device_connection(
            Connection {
                port: Box::new(client),
                sequence: 0,
                deadline: Instant::now(),
                healthy: false,
            },
            || count.get() == 2,
            |cart| assert!(cart.is_none()),
            |sd| {
                assert!(sd.present && sd.error.is_none());
                count.set(count.get() + 1);
            },
            |status| modes.push(status.enabled),
            |_| Ok(()),
        )
        .unwrap();
        peer.join().unwrap();
        assert_eq!(modes, vec![Some(true), Some(false), Some(true)]);
        assert_eq!(count.get(), 2);
    }
    use super::*;

    #[allow(clippy::struct_excessive_bools)]
    struct FakeCart {
        memory: Vec<u8>,
        bank: usize,
        id: Option<u8>,
        id_mode: bool,
        erases: usize,
        programs: usize,
        range_bytes: usize,
        alias_banks: bool,
        corrupt_program: bool,
        protected_tail: bool,
    }
    impl FakeCart {
        fn new(size: usize, id: Option<u8>) -> Self {
            Self {
                memory: vec![0; size],
                bank: 1,
                id,
                id_mode: false,
                erases: 0,
                programs: 0,
                range_bytes: 0,
                alias_banks: false,
                corrupt_program: false,
                protected_tail: false,
            }
        }
        fn offset(&self, address: u16) -> usize {
            if address < 0x4000 {
                usize::from(address)
            } else {
                self.bank * 0x4000 + usize::from(address) - 0x4000
            }
        }
    }
    impl Cart for FakeCart {
        fn read_range(&mut self, address: u16, blocks: u8) -> Result<Vec<u8>, BackupError> {
            self.range_bytes += usize::from(blocks) * BLOCK;
            let mut bytes = Vec::new();
            for index in 0..blocks {
                bytes.extend(self.read(address + u16::from(index) * 1024)?);
            }
            Ok(bytes)
        }

        fn read(&mut self, address: u16) -> Result<Vec<u8>, BackupError> {
            if self.id_mode {
                let mut data = vec![0; BLOCK];
                data[0] = 0xbf;
                data[1] = self.id.unwrap();
                return Ok(data);
            }
            let offset = self.offset(address);
            Ok(self.memory[offset..offset + BLOCK].to_vec())
        }
        fn writes(&mut self, commands: &[(u16, u8)]) -> Result<(), BackupError> {
            match commands {
                [(0, 0xf0)] => self.id_mode = false,
                [(0xaaa, 0xaa), (0x555, 0x55), (0xaaa, 0x90)] => {
                    self.id_mode = self.id.is_some();
                }
                [
                    (0xaaa, 0xaa),
                    (0x555, 0x55),
                    (0xaaa, 0x80),
                    (0xaaa, 0xaa),
                    (0x555, 0x55),
                    (0xaaa, 0x10),
                ] => {
                    self.erases += 1;
                    self.memory.fill(0xff);
                    if self.protected_tail {
                        *self.memory.last_mut().unwrap() = 0;
                    }
                }
                _ => panic!("unexpected flash command sequence: {commands:?}"),
            }
            Ok(())
        }
        fn bank(&mut self, bank: usize) -> Result<u16, BackupError> {
            self.bank = if self.alias_banks { bank % 2 } else { bank };
            Ok(0x4000)
        }
        fn program(&mut self, address: u16, mode: u8, data: &[u8]) -> Result<(), BackupError> {
            assert!(matches!(mode, 0x82 | 0x83 | 0x85));
            let offset = self.offset(address);
            for (old, new) in self.memory[offset..].iter_mut().zip(data) {
                *old &= new;
            }
            if self.corrupt_program {
                self.memory[offset] ^= 1;
            }
            self.programs += 1;
            Ok(())
        }
    }

    fn small_profile() -> Profile {
        let mut result = profile("modretro").unwrap();
        result.flash_size = 0x10000;
        result
    }

    #[test]
    fn identifies_both_modretro_chips_and_resets_read_mode() {
        for id in [0xc8, 0xc9] {
            let mut cart = FakeCart::new(0x10000, Some(id));
            assert_eq!(identify(&mut cart, &small_profile()).unwrap(), [0xbf, id]);
            assert!(!cart.id_mode);
            assert_eq!(cart.erases, 0);
        }
    }
    #[test]
    fn rejects_mask_rom_unknown_id_and_rom_bytes_that_look_like_id() {
        for id in [None, Some(0x42), Some(0xc8)] {
            let mut cart = FakeCart::new(0x10000, id);
            cart.memory[..2].copy_from_slice(&[0xbf, 0xc8]);
            assert!(identify(&mut cart, &small_profile()).is_err());
            assert_eq!(cart.erases, 0);
            assert_eq!(cart.programs, 0);
        }
    }
    #[test]
    fn programs_across_banks_and_erases_unused_tail() {
        let mut cart = FakeCart::new(0x10000, Some(0xc8));
        let mut rom = vec![0x5a; 0x8000];
        rom[0x4000..].fill(0xa5);
        program_rom(&mut cart, &small_profile(), &rom, &mut |_| {}).unwrap();
        assert_eq!(&cart.memory[..rom.len()], rom);
        assert!(cart.memory[rom.len()..].iter().all(|byte| *byte == 0xff));
        assert_eq!(cart.erases, 1);
        assert_eq!(cart.range_bytes, 0x10000, "one combined ROM/tail readback");
    }
    #[test]
    fn catches_write_failure_and_protected_tail() {
        let mut cart = FakeCart::new(0x10000, Some(0xc9));
        cart.protected_tail = true;
        let rom = vec![0x5a; 0x8000];
        assert!(program_rom(&mut cart, &small_profile(), &rom, &mut |_| {}).is_err());
        assert_eq!(cart.programs, 32);
        let mut cart = FakeCart::new(0x10000, Some(0xc9));
        cart.corrupt_program = true;
        assert!(program_rom(&mut cart, &small_profile(), &rom, &mut |_| {}).is_err());
        assert_eq!(cart.programs, 32);
    }
    #[test]
    fn final_read_pass_detects_aliased_banks() {
        let mut cart = FakeCart::new(0x10000, Some(0xc9));
        cart.alias_banks = true;
        let mut rom = vec![0xff; 0x10000];
        rom[..0x8000].fill(0xaa);
        rom[0x8000..].fill(0x88);
        let error = program_rom(&mut cart, &small_profile(), &rom, &mut |_| {}).unwrap_err();
        assert!(error.to_string().contains("final ROM/tail verification"));
        assert_eq!(cart.programs, 64);
    }
    #[test]
    fn final_verification_checks_ff_blocks_skipped_during_programming() {
        let mut cart = FakeCart::new(0x10000, Some(0xc8));
        cart.protected_tail = true;
        let mut rom = vec![0xff; 0x10000];
        rom[..0x4000].fill(0x5a);
        let error = program_rom(&mut cart, &small_profile(), &rom, &mut |_| {}).unwrap_err();
        assert!(error.to_string().contains("final ROM/tail verification"));
        assert_eq!(cart.programs, 16);
        assert_eq!(cart.range_bytes, 0x10000);
    }
    #[test]
    fn validates_4mib_cfi_before_erase() {
        let mut cfi = vec![0; BLOCK];
        cfi[0x20] = b'Q';
        cfi[0x22] = b'R';
        cfi[0x24] = b'Y';
        cfi[0x26] = 2;
        cfi[0x4e] = 22;
        cfi[0x54] = 5;
        cfi[0x40] = 10;
        cfi[0x48] = 4;
        validate_cfi(&cfi, 4 << 20).unwrap();
        for (offset, value) in [
            (0x20, 0),
            (0x26, 1),
            (0x4e, 23),
            (0x54, 4),
            (0x48, 10),
            (0x44, 64),
        ] {
            let mut bad = cfi.clone();
            bad[offset] = value;
            assert!(validate_cfi(&bad, 4 << 20).is_err());
        }
        assert!(validate_cfi(&cfi[..0x20], 4 << 20).is_err());
    }

    #[test]
    fn buffered_profile_uses_same_banked_program_and_verify_path() {
        let mut p = small_profile();
        p.buffered = true;
        let mut cart = FakeCart::new(p.flash_size, Some(0xc8));
        let mut rom = vec![0x31; 0x8000];
        rom[0x4000..].fill(0xc2);
        program_rom(&mut cart, &p, &rom, &mut |_| {}).unwrap();
        assert_eq!(&cart.memory[..rom.len()], rom);
    }

    #[test]
    fn request_crc_covers_program_data_and_commands() {
        let payload = [2, 0xaa, 0x0a, 0x90];
        let bytes = frame(123, &payload).unwrap();
        assert_eq!(&bytes[..4], b"CF01");
        assert_eq!(&bytes[4..8], &123_u32.to_le_bytes());
        assert_eq!(&bytes[8..12], &4_u32.to_le_bytes());
        assert_eq!(&bytes[12..16], &crc32fast::hash(&payload).to_le_bytes());
        assert!(frame(0, &vec![0; 1537]).is_err());
    }
    fn seal_rom(rom: &mut [u8]) {
        rom[0x14d] = rom[0x134..0x14d]
            .iter()
            .fold(0_u8, |sum, byte| sum.wrapping_sub(*byte).wrapping_sub(1));
        let sum = rom
            .iter()
            .enumerate()
            .filter(|(i, _)| !matches!(i, 0x14e | 0x14f))
            .fold(0_u16, |sum, (_, byte)| sum.wrapping_add(u16::from(*byte)));
        rom[0x14e..0x150].copy_from_slice(&sum.to_be_bytes());
    }

    #[test]
    fn validates_rom_geometry_and_checksums_independently_of_game_mapper() {
        let mut rom = crate::rom::tests::valid_rom();
        for mapper in [0x00, 0x03, 0x10, 0x1b] {
            rom[0x147] = mapper;
            seal_rom(&mut rom);
            let original = rom.clone();
            validate_rom(&rom, 0x0020_0000).unwrap();
            assert_eq!(rom, original);
        }
        rom[0x148] = 1;
        seal_rom(&mut rom);
        assert!(validate_rom(&rom, 0x0020_0000).is_err());
        rom[0x148] = 0;
        rom[0x147] = 0x10;
        seal_rom(&mut rom);
        validate_rom(&rom, 0x0020_0000).unwrap();
        assert!(validate_rom(&rom, 0x4000).is_err());
        rom[0x200] ^= 1;
        assert!(validate_rom(&rom, 0x0020_0000).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn watches_physical_writability_and_reprobes_after_removal() {
        for id in [None, Some(0xc8)] {
            watch_physical_cart(id);
        }
    }

    #[cfg(unix)]
    #[allow(clippy::too_many_lines)]
    fn watch_physical_cart(id: Option<u8>) {
        use std::cell::Cell;
        use std::io::Read as _;
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(100)).unwrap();
        device.set_timeout(Duration::from_secs(3)).unwrap();
        let mut rom = crate::rom::tests::valid_rom();
        rom[0x147] = 0x10;
        seal_rom(&mut rom);
        let header = crate::rom::inspect_header(&rom).unwrap();
        let mut rewritten = rom.clone();
        rewritten[0x134..0x13b].copy_from_slice(b"NEWGAME");
        rewritten[0x147] = 0x1b;
        seal_rom(&mut rewritten);
        let rewritten_header = crate::rom::inspect_header(&rewritten).unwrap();
        let peer = std::thread::spawn(move || {
            let mut cart = FakeCart::new(0x10000, id);
            let mut probes = 0;
            for data in [
                vec![0xff; BLOCK],
                rom[..BLOCK].to_vec(),
                rom[..BLOCK].to_vec(),
                vec![0xff; BLOCK],
                rom[..BLOCK].to_vec(),
                rewritten[..BLOCK].to_vec(),
            ] {
                cart.memory[..BLOCK].copy_from_slice(&data);
                let mut command = Vec::new();
                loop {
                    let mut byte = [0];
                    device.read_exact(&mut byte).unwrap();
                    if byte[0] == b'\r' {
                        if command.is_empty() {
                            continue;
                        }
                        break;
                    }
                    command.push(byte[0]);
                }
                assert_eq!(command, b"pcflash --mapper 1b");
                device
                    .write_all(b"PCFLASH READY protocol=2 bulk=3 block=1024\n")
                    .unwrap();
                for sequence in 0.. {
                    let mut header = [0; 16];
                    device.read_exact(&mut header).unwrap();
                    let size = u32::from_le_bytes(header[8..12].try_into().unwrap()) as usize;
                    assert!(size <= 1536);
                    let mut payload = vec![0; size];
                    device.read_exact(&mut payload).unwrap();
                    assert_eq!(header, frame(sequence, &payload).unwrap()[..16]);
                    let reply = match payload.as_slice() {
                        [0] => Vec::new(),
                        [1, lo, hi] => cart.read(u16::from_le_bytes([*lo, *hi])).unwrap(),
                        [3, a, b, c, d] => cart
                            .bank(u32::from_le_bytes([*a, *b, *c, *d]) as usize)
                            .unwrap()
                            .to_le_bytes()
                            .to_vec(),
                        [2, commands @ ..] => {
                            let commands: Vec<_> = commands
                                .chunks_exact(3)
                                .map(|c| (u16::from_le_bytes([c[0], c[1]]), c[2]))
                                .collect();
                            if commands == [(0xaaa, 0xaa), (0x555, 0x55), (0xaaa, 0x90)] {
                                probes += 1;
                            } else {
                                assert_eq!(
                                    commands,
                                    [(0, 0xf0)],
                                    "only identification/reset writes are allowed"
                                );
                            }
                            cart.writes(&commands).unwrap();
                            Vec::new()
                        }
                        _ => panic!("discovery must not erase/program"),
                    };
                    let encoded = if reply.is_empty() {
                        "-".to_owned()
                    } else {
                        base64::engine::general_purpose::STANDARD.encode(&reply)
                    };
                    writeln!(
                        device,
                        "PCFLASH OK seq={sequence} size={} crc={:08x} data={encoded}",
                        reply.len(),
                        crc32fast::hash(&reply)
                    )
                    .unwrap();
                    if payload == [0] {
                        device.write_all(b"PCFLASH PASS error=ESP_OK\n").unwrap();
                        assert!(!cart.id_mode);
                        break;
                    }
                }
            }
            assert_eq!(
                probes, 3,
                "probe once per insertion or rewritten header, not on every poll"
            );
            assert_eq!(cart.erases, 0);
            assert_eq!(cart.programs, 0);
            std::thread::sleep(Duration::from_millis(100));
        });
        let stopped = Cell::new(false);
        let mut states = Vec::new();
        watch_connection(
            Connection {
                port: Box::new(client),
                sequence: 0,
                deadline: Instant::now(),
                healthy: false,
            },
            || stopped.get(),
            |state| {
                states.push(state);
                if states.len() == 5 {
                    stopped.set(true);
                }
            },
        )
        .unwrap();
        peer.join().unwrap();
        let known = Some(InspectedCartridge {
            header,
            rom_writable: id.is_some(),
            cart_size: id.map(|_| 2 << 20),
        });
        assert_eq!(
            states,
            vec![
                None,
                known.clone(),
                None,
                known,
                Some(InspectedCartridge {
                    header: rewritten_header,
                    rom_writable: id.is_some(),
                    cart_size: id.map(|_| 2 << 20),
                })
            ]
        );
    }

    #[cfg(unix)]
    fn exchange_response(response: &[u8], expected: usize) -> (Result<Vec<u8>, BackupError>, bool) {
        exchange_payload_response(&[3, 0, 0, 0, 0], response, expected)
    }

    #[cfg(unix)]
    fn exchange_payload_response(
        payload: &[u8],
        response: &[u8],
        expected: usize,
    ) -> (Result<Vec<u8>, BackupError>, bool) {
        use std::io::Read as _;
        let response = response.to_vec();
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(100)).unwrap();
        device.set_timeout(Duration::from_secs(2)).unwrap();
        let peer = std::thread::spawn(move || {
            let mut header = [0; 16];
            device.read_exact(&mut header).unwrap();
            let size = u32::from_le_bytes(header[8..12].try_into().unwrap());
            let mut payload = vec![0; usize::try_from(size).unwrap()];
            device.read_exact(&mut payload).unwrap();
            assert_eq!(header[..4], *b"CF01");
            assert_eq!(
                crc32fast::hash(&payload),
                u32::from_le_bytes(header[12..16].try_into().unwrap())
            );
            device.write_all(&response).unwrap();
            std::thread::sleep(Duration::from_millis(100));
        });
        let mut connection = Connection {
            port: Box::new(client),
            sequence: 0,
            deadline: Instant::now() + Duration::from_secs(2),
            healthy: true,
        };
        let result = connection.exchange(payload, expected);
        peer.join().unwrap();
        (result, connection.healthy)
    }

    #[cfg(unix)]
    #[test]
    fn verifies_direct_bulk_data_and_crc_without_text_encoding_payload() {
        let data: Vec<u8> = (0..BLOCK).map(|n| n.to_le_bytes()[0]).collect();
        let crc = crc32fast::hash(&data).to_le_bytes();
        let mut reply = format!("PCFLASH BULK size={}\n", data.len()).into_bytes();
        reply.extend(&data);
        reply.extend(
            format!(
                "PCFLASH OK seq=0 size=4 crc={:08x} data={}\n",
                crc32fast::hash(&crc),
                base64::engine::general_purpose::STANDARD.encode(crc)
            )
            .as_bytes(),
        );
        let (result, healthy) = exchange_payload_response(&[5, 0, 0x40, 1], &reply, 4);
        assert_eq!(result.unwrap(), data);
        assert!(healthy);
        reply[30] ^= 1;
        let (result, healthy) = exchange_payload_response(&[5, 0, 0x40, 1], &reply, 4);
        assert!(result.is_err());
        assert!(!healthy);
        let (result, healthy) =
            exchange_payload_response(&[5, 0, 0x40, 1], b"PCFLASH BULK size=2048\n", 4);
        assert!(result.is_err());
        assert!(!healthy);
    }

    #[cfg(unix)]
    #[test]
    fn rejects_corrupt_out_of_order_and_failed_device_replies() {
        for reply in [
            b"PCFLASH OK seq=1 size=0 crc=00000000 data=-\n".as_slice(),
            b"PCFLASH OK seq=0 size=0 crc=00000001 data=-\n".as_slice(),
            b"PCFLASH FAIL error=ESP_ERR_INVALID_CRC\n".as_slice(),
            b"PCFLASH OK seq=0 seq=0 size=0 crc=00000000 data=-\n".as_slice(),
        ] {
            let (result, healthy) = exchange_response(reply, 0);
            assert!(result.is_err());
            assert!(!healthy);
        }
        let (result, healthy) =
            exchange_response(b"PCFLASH OK seq=0 size=0 crc=00000000 data=-\n", 0);
        assert_eq!(result.unwrap(), Vec::<u8>::new());
        assert!(healthy);
    }
}
