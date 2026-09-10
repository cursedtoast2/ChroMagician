//! Reusable host-side client for Chromatic cartridge backups.

mod firmware;
mod flash;
pub use firmware::{DeviceStatus, FirmwareInfo, firmware_info, firmware_info_after_flash};
mod sd;
pub use sd::{SdEntry, SdOperation, SdStatus, sd_files};
mod protocol;
mod rom;

pub use flash::{
    FLASH_PROFILES, InspectedCartridge, RomWriteEvent, RomWriteRequest, RomWriteResult,
    inspect_cartridge, probe_flash, watch_cartridge, watch_device, write_rom,
};
pub use rom::CartridgeHeader;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
#[cfg(unix)]
use std::fs::File;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use base64::Engine as _;
use crc32fast::Hasher;
use serde::Serialize;
use serialport::{DataBits, FlowControl, Parity, SerialPort, SerialPortType, StopBits};
use tempfile::{Builder as TempFileBuilder, NamedTempFile};
use thiserror::Error;

use protocol::{ImportRecord, Record, parse_import_record, parse_record};
use rom::RomValidator;

pub const USB_VID: u16 = 0x374e;
pub const USB_PID: u16 = 0x0101;
pub const EVENT_SCHEMA_VERSION: u8 = 1;
const BAUD_RATE: u32 = 2_000_000;
const DIRECT_BLOCK_SIZE: u64 = 1024;
const LINE_LIMIT: usize = 4096;

/// A complete backup request. Save requests automatically include RTC data when present.
#[derive(Debug, Clone)]
pub struct BackupRequest {
    pub port: Option<String>,
    pub rom_path: Option<PathBuf>,
    pub save_path: Option<PathBuf>,
    pub force: bool,
    pub timeout: Duration,
    pub boot_wait: Duration,
}

impl Default for BackupRequest {
    fn default() -> Self {
        Self {
            port: None,
            rom_path: None,
            save_path: None,
            force: false,
            timeout: Duration::from_mins(5),
            boot_wait: Duration::from_secs(3),
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ArtifactKind {
    Rom,
    Save,
    Rtc,
}

impl ArtifactKind {
    fn protocol_name(self) -> &'static str {
        match self {
            Self::Rom => "rom",
            Self::Save => "sav",
            Self::Rtc => "rtc",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CartridgeInfo {
    pub title: String,
    pub cartridge_type: u8,
    pub color: bool,
    pub rom_size: u64,
    pub save_size: u64,
    pub has_rtc: bool,
}

/// Stable progress events intended for either a terminal renderer or JSON Lines IPC.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum BackupEvent {
    SessionStarted {
        schema_version: u8,
    },
    DeviceConnected {
        port: String,
    },
    CartridgeDetected {
        cartridge: CartridgeInfo,
    },
    ArtifactStarted {
        kind: ArtifactKind,
        path: PathBuf,
        size: u64,
    },
    Progress {
        kind: ArtifactKind,
        received: u64,
        total: u64,
        percent: u8,
    },
    ArtifactVerified {
        kind: ArtifactKind,
        size: u64,
        crc32: String,
    },
    ArtifactSaved {
        kind: ArtifactKind,
        path: PathBuf,
    },
    Complete {
        elapsed_ms: u128,
    },
}

#[derive(Debug, Clone)]
pub struct BackupResult {
    pub cartridge: CartridgeInfo,
    pub artifacts: BTreeMap<ArtifactKind, PathBuf>,
    pub elapsed: Duration,
}

/// A physical-cartridge save import. A same-stem `.rtc` file is included
/// automatically when it exists; there is intentionally no separate RTC argument.
#[derive(Debug, Clone)]
pub struct SaveImportRequest {
    pub port: Option<String>,
    pub save_path: PathBuf,
    pub timeout: Duration,
    pub boot_wait: Duration,
    /// Explicitly omit a same-stem RTC sidecar and restore only save RAM.
    pub save_only: bool,
}

impl Default for SaveImportRequest {
    fn default() -> Self {
        Self {
            port: None,
            save_path: PathBuf::new(),
            timeout: Duration::from_mins(5),
            boot_wait: Duration::from_secs(3),
            save_only: false,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SaveImportEvent {
    SessionStarted {
        schema_version: u8,
    },
    DeviceConnected {
        port: String,
    },
    CartridgeDetected {
        cartridge: CartridgeInfo,
    },
    ValidationStarted {
        size: u64,
        rtc_included: bool,
    },
    WriteStarted {
        size: u64,
        rtc_included: bool,
    },
    Progress {
        written: u64,
        total: u64,
        percent: u8,
    },
    Complete {
        elapsed_ms: u128,
    },
}

#[derive(Debug, Clone)]
pub struct SaveImportResult {
    pub cartridge: CartridgeInfo,
    pub save_path: PathBuf,
    pub rtc_path: Option<PathBuf>,
    pub elapsed: Duration,
}

#[derive(Debug, Error)]
pub enum BackupError {
    #[error("at least one of ROM or save output is required")]
    NoOutput,
    #[error("Chromatic USB device not found; connect it or pass --port")]
    DeviceNotFound,
    #[error("multiple Chromatics found; select one with --port: {0}")]
    MultipleDevices(String),
    #[error("serial error: {0}")]
    Serial(#[from] serialport::Error),
    #[error("I/O error: {0}")]
    Io(#[from] io::Error),
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("device failed: {0}")]
    Device(String),
    #[error("timed out; confirm PC BACKUP is enabled in System settings")]
    Timeout,
    #[error("output exists (use --force): {0}")]
    OutputExists(PathBuf),
    #[error("ROM validation failed: {0}")]
    InvalidRom(String),
    #[error("save input is invalid: {0}")]
    InvalidSave(String),
    #[error("flash cartridge error: {0}")]
    Flash(String),
}

impl BackupError {
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::NoOutput => "invalid_request",
            Self::DeviceNotFound | Self::MultipleDevices(_) => "device_not_found",
            Self::Serial(_) | Self::Io(_) => "transport_error",
            Self::Protocol(_) => "protocol_error",
            Self::Device(_) => "device_error",
            Self::Timeout => "timeout",
            Self::OutputExists(_) => "output_exists",
            Self::InvalidRom(_) => "invalid_rom",
            Self::InvalidSave(_) => "invalid_save",
            Self::Flash(_) => "flash_error",
        }
    }
}

fn open_chromatic(
    requested_port: Option<&str>,
    boot_wait: Duration,
) -> Result<(String, Box<dyn SerialPort>), BackupError> {
    let port_name = match requested_port {
        Some(port) => port.to_owned(),
        None => match discover_ports()?.as_slice() {
            [] => return Err(BackupError::DeviceNotFound),
            [port] => port.clone(),
            ports => return Err(BackupError::MultipleDevices(ports.join(", "))),
        },
    };
    let mut port = serialport::new(&port_name, BAUD_RATE)
        .data_bits(DataBits::Eight)
        .flow_control(FlowControl::None)
        .parity(Parity::None)
        .stop_bits(StopBits::One)
        .timeout(Duration::from_millis(250))
        .open()?;
    port.write_data_terminal_ready(false)?;
    port.write_request_to_send(false)?;
    std::thread::sleep(boot_wait);
    port.clear(serialport::ClearBuffer::Input)?;
    port.write_all(b"\r\n")?;
    port.flush()?;
    std::thread::sleep(Duration::from_millis(200));
    port.clear(serialport::ClearBuffer::Input)?;
    Ok((port_name, port))
}

fn write_upload(port: &mut dyn SerialPort, bytes: &[u8]) -> Result<(), BackupError> {
    for chunk in bytes.chunks(128) {
        port.write_all(chunk)?;
        port.flush()?;
        std::thread::sleep(Duration::from_millis(1));
    }
    Ok(())
}

/// Return all connected Chromatic USB CDC ports.
///
/// # Errors
///
/// Returns a serial-platform error when the operating system cannot enumerate ports.
pub fn discover_ports() -> Result<Vec<String>, BackupError> {
    let mut matches = serialport::available_ports()?
        .into_iter()
        .filter_map(|port| match port.port_type {
            SerialPortType::UsbPort(info) if info.vid == USB_VID && info.pid == USB_PID => {
                Some(port.port_name)
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    matches.sort();
    Ok(matches)
}

/// Back up a cartridge while reporting structured progress through `on_event`.
///
/// # Errors
///
/// Returns [`BackupError`] when discovery, transport, device protocol, validation, or output
/// publication fails. Incomplete temporary files are removed before returning an error.
pub fn backup(
    request: &BackupRequest,
    mut on_event: impl FnMut(BackupEvent),
) -> Result<BackupResult, BackupError> {
    on_event(BackupEvent::SessionStarted {
        schema_version: EVENT_SCHEMA_VERSION,
    });
    if request.rom_path.is_none() && request.save_path.is_none() {
        return Err(BackupError::NoOutput);
    }

    let (port_name, mut port) = open_chromatic(request.port.as_deref(), request.boot_wait)?;
    on_event(BackupEvent::DeviceConnected {
        port: port_name.clone(),
    });

    let mut flags = Vec::with_capacity(2);
    if request.rom_path.is_some() {
        flags.push("--rom");
    }
    if request.save_path.is_some() {
        flags.push("--sav");
    }
    writeln!(port, "pcbackup {}\r", flags.join(" "))?;
    port.flush()?;

    let started = Instant::now();
    let deadline = started + request.timeout;
    let mut receiver = Receiver::new(request);
    let run_result = receive_loop(&mut *port, &mut receiver, deadline, &mut on_event);
    if run_result.is_err() {
        receiver.cleanup();
    }
    run_result?;

    let artifacts = match receiver.publish(&mut on_event) {
        Ok(artifacts) => artifacts,
        Err(error) => {
            receiver.cleanup();
            return Err(error);
        }
    };
    let cartridge = receiver
        .cartridge
        .clone()
        .ok_or_else(|| BackupError::Protocol("device omitted cartridge information".into()))?;
    let elapsed = started.elapsed();
    on_event(BackupEvent::Complete {
        elapsed_ms: elapsed.as_millis(),
    });
    Ok(BackupResult {
        cartridge,
        artifacts,
        elapsed,
    })
}

struct SaveImporter<'a> {
    save: &'a [u8],
    rtc: Option<&'a [u8]>,
    cartridge: Option<CartridgeInfo>,
    write_started: bool,
}

impl SaveImporter<'_> {
    fn info(
        &mut self,
        fields: &BTreeMap<String, String>,
        on_event: &mut impl FnMut(SaveImportEvent),
    ) -> Result<(), BackupError> {
        if self.cartridge.is_some() {
            return Err(BackupError::Protocol(
                "duplicate cartridge information".into(),
            ));
        }
        let info = parse_cartridge_info(fields, "1")?;
        if info.save_size != self.save.len() as u64 {
            return Err(BackupError::InvalidSave(format!(
                "file has {} bytes but {} requires {}",
                self.save.len(),
                if info.title.is_empty() {
                    "the cartridge"
                } else {
                    &info.title
                },
                info.save_size
            )));
        }
        if self.rtc.is_some() && !info.has_rtc {
            return Err(BackupError::InvalidSave(
                "same-stem RTC sidecar exists but no physical RTC was confirmed; nothing written; use --save-only to restore just save RAM".into(),
            ));
        }
        on_event(SaveImportEvent::CartridgeDetected {
            cartridge: info.clone(),
        });
        self.cartridge = Some(info);
        Ok(())
    }

    fn ready(
        &mut self,
        fields: &BTreeMap<String, String>,
        on_event: &mut impl FnMut(SaveImportEvent),
    ) -> Result<(), BackupError> {
        match field(fields, "phase")? {
            "validate" => on_event(SaveImportEvent::ValidationStarted {
                size: self.save.len() as u64,
                rtc_included: self.rtc.is_some(),
            }),
            "write" => {
                self.write_started = true;
                on_event(SaveImportEvent::WriteStarted {
                    size: self.save.len() as u64,
                    rtc_included: self.rtc.is_some(),
                });
            }
            phase => {
                return Err(BackupError::Protocol(format!(
                    "unknown import phase {phase:?}"
                )));
            }
        }
        Ok(())
    }

    fn send(
        &self,
        fields: &BTreeMap<String, String>,
        port: &mut dyn SerialPort,
    ) -> Result<(), BackupError> {
        let kind = field(fields, "kind")?;
        let offset = usize::try_from(parse_decimal(field(fields, "offset")?, "import offset")?)
            .map_err(|_| BackupError::Protocol("import offset is too large".into()))?;
        let size = usize::try_from(parse_decimal(field(fields, "size")?, "import block size")?)
            .map_err(|_| BackupError::Protocol("import block is too large".into()))?;
        let bytes = match kind {
            "sav" => self.save.get(offset..offset.saturating_add(size)),
            "rtc" if offset == 0 && size == 4 => self.rtc,
            _ => None,
        }
        .ok_or_else(|| {
            BackupError::Protocol(format!(
                "device requested invalid {kind} range {offset}..{}",
                offset.saturating_add(size)
            ))
        })?;
        write_upload(port, bytes)
    }

    fn progress(
        fields: &BTreeMap<String, String>,
        on_event: &mut impl FnMut(SaveImportEvent),
    ) -> Result<(), BackupError> {
        let written = parse_decimal(field(fields, "written")?, "written size")?;
        let total = parse_decimal(field(fields, "total")?, "total size")?;
        let percent = written
            .saturating_mul(100)
            .checked_div(total)
            .and_then(|value| u8::try_from(value).ok())
            .unwrap_or(100);
        on_event(SaveImportEvent::Progress {
            written,
            total,
            percent,
        });
        Ok(())
    }
}

struct ImportFiles {
    save: Vec<u8>,
    rtc_path: PathBuf,
    rtc: Option<Vec<u8>>,
}

fn read_import_files(save_path: &Path, save_only: bool) -> Result<ImportFiles, BackupError> {
    let save = fs::read(save_path)?;
    let rtc_path = save_path.with_extension("rtc");
    let rtc = if !save_only && rtc_path.exists() {
        let bytes = fs::read(&rtc_path)?;
        if bytes.len() != 4 {
            return Err(BackupError::InvalidSave(format!(
                "{} must contain exactly four bytes",
                rtc_path.display()
            )));
        }
        let state = u32::from_le_bytes(bytes.as_slice().try_into().map_err(|_| {
            BackupError::InvalidSave("RTC sidecar length changed while reading".into())
        })?);
        if !rtc_state_is_valid(state) {
            return Err(BackupError::InvalidSave(format!(
                "{} contains an invalid RTC state",
                rtc_path.display()
            )));
        }
        Some(bytes)
    } else {
        None
    };
    Ok(ImportFiles {
        save,
        rtc_path,
        rtc,
    })
}

/// Import save RAM into a physical cartridge and verify it block-by-block.
///
/// The device performs a complete CRC validation pass before the first write.
/// The same-stem RTC sidecar, when present, is validated and imported as part
/// of the save operation.
///
/// # Errors
///
/// Returns [`BackupError`] when the file, cartridge geometry, transport, write,
/// or read-back verification fails.
pub fn import_save(
    request: &SaveImportRequest,
    mut on_event: impl FnMut(SaveImportEvent),
) -> Result<SaveImportResult, BackupError> {
    on_event(SaveImportEvent::SessionStarted {
        schema_version: EVENT_SCHEMA_VERSION,
    });
    if request.save_path.as_os_str().is_empty() {
        return Err(BackupError::InvalidSave("save path is required".into()));
    }
    let ImportFiles {
        save,
        rtc_path,
        rtc,
    } = read_import_files(&request.save_path, request.save_only)?;
    let save_crc = crc32fast::hash(&save);
    let rtc_crc = rtc.as_ref().map(|bytes| crc32fast::hash(bytes));

    let (port_name, mut port) = open_chromatic(request.port.as_deref(), request.boot_wait)?;
    on_event(SaveImportEvent::DeviceConnected {
        port: port_name.clone(),
    });
    write!(port, "pcimport --size {} --crc {save_crc:08x}", save.len())?;
    if let Some(crc) = rtc_crc {
        write!(port, " --rtc-crc {crc:08x}")?;
    }
    port.write_all(b"\r")?;
    port.flush()?;

    let started = Instant::now();
    let deadline = started + request.timeout;
    let mut importer = SaveImporter {
        save: &save,
        rtc: rtc.as_deref(),
        cartridge: None,
        write_started: false,
    };
    while Instant::now() < deadline {
        let Some(line) = read_line_until(&mut *port, deadline)? else {
            continue;
        };
        let Some(prefix) = find_subslice(&line, b"PCIMPORT ") else {
            continue;
        };
        let Ok(record_text) = std::str::from_utf8(&line[prefix..]) else {
            continue;
        };
        match parse_import_record(record_text.trim_end())? {
            ImportRecord::Info(fields) => {
                importer.info(&fields, &mut on_event)?;
            }
            ImportRecord::Ready(fields) => {
                importer.ready(&fields, &mut on_event)?;
            }
            ImportRecord::Send(fields) => {
                importer.send(&fields, &mut *port)?;
            }
            ImportRecord::Progress(fields) => {
                SaveImporter::progress(&fields, &mut on_event)?;
            }
            ImportRecord::Fail(fields) => {
                return Err(BackupError::Device(
                    fields
                        .get("error")
                        .cloned()
                        .unwrap_or_else(|| "unknown error".into()),
                ));
            }
            ImportRecord::Pass => {
                if !importer.write_started {
                    return Err(BackupError::Protocol(
                        "device reported PASS before the write phase".into(),
                    ));
                }
                let cartridge = importer.cartridge.ok_or_else(|| {
                    BackupError::Protocol("device omitted cartridge information".into())
                })?;
                let elapsed = started.elapsed();
                on_event(SaveImportEvent::Complete {
                    elapsed_ms: elapsed.as_millis(),
                });
                return Ok(SaveImportResult {
                    cartridge,
                    save_path: request.save_path.clone(),
                    rtc_path: rtc.as_ref().map(|_| rtc_path),
                    elapsed,
                });
            }
        }
    }
    Err(BackupError::Timeout)
}

fn receive_loop(
    port: &mut dyn SerialPort,
    receiver: &mut Receiver,
    deadline: Instant,
    on_event: &mut impl FnMut(BackupEvent),
) -> Result<(), BackupError> {
    while Instant::now() < deadline {
        if let Some(bytes_needed) = receiver.direct_bytes_needed() {
            let amount = usize::try_from(bytes_needed.min(16 * 1024)).unwrap_or(16 * 1024);
            let data = read_exact_until(port, amount, deadline)?;
            receiver.direct_data(&data, on_event)?;
            continue;
        }

        let Some(line) = read_line_until(port, deadline)? else {
            continue;
        };
        let Some(prefix) = find_subslice(&line, b"PCBACKUP ") else {
            continue;
        };
        let Ok(record_text) = std::str::from_utf8(&line[prefix..]) else {
            continue;
        };
        let record = parse_record(record_text.trim_end())?;
        match record {
            Record::Info(fields) => receiver.configure(&fields, on_event)?,
            Record::Begin(fields) => receiver.begin(&fields, on_event)?,
            Record::Data(fields) => receiver.encoded_data(&fields, on_event)?,
            Record::End(fields) => receiver.end(&fields, on_event)?,
            Record::Fail(fields) => {
                return Err(BackupError::Device(
                    fields
                        .get("error")
                        .cloned()
                        .unwrap_or_else(|| "unknown error".into()),
                ));
            }
            Record::Pass => return Ok(()),
        }
    }
    Err(BackupError::Timeout)
}

fn read_line_until(
    port: &mut dyn SerialPort,
    deadline: Instant,
) -> Result<Option<Vec<u8>>, BackupError> {
    let mut bytes = Vec::new();
    let mut byte = [0_u8; 1];
    while Instant::now() < deadline {
        match port.read(&mut byte) {
            Ok(0) => {}
            Ok(_) if byte[0] == b'\n' => {
                return Ok(Some(bytes));
            }
            Ok(_) => {
                if bytes.len() == LINE_LIMIT {
                    bytes.clear();
                }
                bytes.push(byte[0]);
            }
            Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(None)
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn read_exact_until(
    port: &mut dyn SerialPort,
    size: usize,
    deadline: Instant,
) -> Result<Vec<u8>, BackupError> {
    let mut result = vec![0; size];
    let mut received = 0;
    while received < size && Instant::now() < deadline {
        match port.read(&mut result[received..]) {
            Ok(0) => {}
            Ok(count) => received += count,
            Err(error) if error.kind() == io::ErrorKind::TimedOut => {}
            Err(error) => return Err(error.into()),
        }
    }
    if received != size {
        return Err(BackupError::Protocol(format!(
            "timed out receiving direct USB data ({received}/{size} bytes)"
        )));
    }
    Ok(result)
}

fn parse_cartridge_info(
    fields: &BTreeMap<String, String>,
    expected_protocol: &str,
) -> Result<CartridgeInfo, BackupError> {
    if field(fields, "protocol")? != expected_protocol || field(fields, "transport")? != "usb-bulk"
    {
        return Err(BackupError::Protocol(format!(
            "firmware does not provide USB bulk protocol {expected_protocol}"
        )));
    }
    let color = parse_decimal(field(fields, "color")?, "color flag")? != 0;
    Ok(CartridgeInfo {
        title: decode_title(field(fields, "title")?, color)?,
        cartridge_type: parse_hex_u8(field(fields, "type")?, "cartridge type")?,
        color,
        rom_size: parse_decimal(field(fields, "rom")?, "ROM size")?,
        save_size: parse_decimal(field(fields, "sav")?, "save size")?,
        has_rtc: parse_decimal(field(fields, "rtc")?, "RTC flag")? != 0,
    })
}

fn rtc_state_is_valid(state: u32) -> bool {
    let seconds = state & 0x3f;
    let minutes = (state >> 6) & 0x3f;
    let hours = (state >> 12) & 0x1f;
    let days = (state >> 17) & 0x3ff;
    state & 0xe000_0000 == 0 && seconds <= 59 && minutes <= 59 && hours <= 23 && days <= 511
}

struct PendingArtifact {
    kind: ArtifactKind,
    expected_size: u64,
    logical_received: u64,
    wire_received: u64,
    next_sequence: u64,
    last_percent: Option<u8>,
    crc: Hasher,
    rom_validator: Option<RomValidator>,
    temp: NamedTempFile,
}

struct Receiver {
    requested_outputs: BTreeMap<ArtifactKind, PathBuf>,
    force: bool,
    cartridge: Option<CartridgeInfo>,
    mbc2_save: bool,
    current: Option<PendingArtifact>,
    completed: BTreeMap<ArtifactKind, CompletedArtifact>,
}

struct CompletedArtifact {
    final_path: PathBuf,
    temp: NamedTempFile,
}

impl Receiver {
    fn new(request: &BackupRequest) -> Self {
        let mut requested_outputs = BTreeMap::new();
        if let Some(path) = &request.rom_path {
            requested_outputs.insert(ArtifactKind::Rom, path.clone());
        }
        if let Some(path) = &request.save_path {
            requested_outputs.insert(ArtifactKind::Save, path.clone());
        }
        Self {
            requested_outputs,
            force: request.force,
            cartridge: None,
            mbc2_save: false,
            current: None,
            completed: BTreeMap::new(),
        }
    }

    fn configure(
        &mut self,
        fields: &BTreeMap<String, String>,
        on_event: &mut impl FnMut(BackupEvent),
    ) -> Result<(), BackupError> {
        if self.cartridge.is_some() {
            return Err(BackupError::Protocol(
                "duplicate cartridge information".into(),
            ));
        }
        let info = parse_cartridge_info(fields, "2")?;
        let cartridge_type = info.cartridge_type;
        self.mbc2_save = matches!(cartridge_type, 0x05 | 0x06);

        if let Some(save_path) = self.requested_outputs.get(&ArtifactKind::Save).cloned() {
            if info.save_size == 0 {
                self.requested_outputs.remove(&ArtifactKind::Save);
            }
            if info.has_rtc {
                self.requested_outputs
                    .insert(ArtifactKind::Rtc, save_path.with_extension("rtc"));
            }
            if info.save_size == 0 && !info.has_rtc {
                return Err(BackupError::Protocol(
                    "cartridge has no save RAM or RTC".into(),
                ));
            }
        }

        let mut unique_paths = BTreeSet::new();
        for path in self.requested_outputs.values() {
            let absolute = absolute_path(path)?;
            if !unique_paths.insert(absolute) {
                return Err(BackupError::Protocol(
                    "ROM, save, and derived RTC outputs must be different files".into(),
                ));
            }
            if path.exists() && !self.force {
                return Err(BackupError::OutputExists(path.clone()));
            }
            if let Some(parent) = path
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
            {
                fs::create_dir_all(parent)?;
            }
        }

        self.cartridge = Some(info.clone());
        on_event(BackupEvent::CartridgeDetected { cartridge: info });
        Ok(())
    }

    fn begin(
        &mut self,
        fields: &BTreeMap<String, String>,
        on_event: &mut impl FnMut(BackupEvent),
    ) -> Result<(), BackupError> {
        if self.current.is_some() {
            return Err(BackupError::Protocol("nested BEGIN record".into()));
        }
        let kind = parse_kind(field(fields, "kind")?)?;
        let Some(final_path) = self.requested_outputs.get(&kind) else {
            return Err(BackupError::Protocol(format!(
                "unexpected BEGIN for {kind:?}"
            )));
        };
        if self.completed.contains_key(&kind) {
            return Err(BackupError::Protocol(format!(
                "duplicate BEGIN for {kind:?}"
            )));
        }
        let expected_size = parse_decimal(field(fields, "size")?, "artifact size")?;
        let cartridge = self
            .cartridge
            .as_ref()
            .ok_or_else(|| BackupError::Protocol("BEGIN received before INFO".into()))?;
        let metadata_size = match kind {
            ArtifactKind::Rom => cartridge.rom_size,
            ArtifactKind::Save => cartridge.save_size,
            ArtifactKind::Rtc => 4,
        };
        if expected_size != metadata_size {
            return Err(BackupError::Protocol(format!(
                "{} size {expected_size} does not match cartridge metadata {metadata_size}",
                kind.protocol_name()
            )));
        }
        let temp = create_part(final_path)?;
        self.current = Some(PendingArtifact {
            kind,
            expected_size,
            logical_received: 0,
            wire_received: 0,
            next_sequence: 0,
            last_percent: None,
            crc: Hasher::new(),
            rom_validator: (kind == ArtifactKind::Rom).then(RomValidator::new),
            temp,
        });
        on_event(BackupEvent::ArtifactStarted {
            kind,
            path: final_path.clone(),
            size: expected_size,
        });
        Ok(())
    }

    fn direct_bytes_needed(&self) -> Option<u64> {
        let current = self.current.as_ref()?;
        if !matches!(current.kind, ArtifactKind::Rom | ArtifactKind::Save) {
            return None;
        }
        let wire_size = current.expected_size.div_ceil(DIRECT_BLOCK_SIZE) * DIRECT_BLOCK_SIZE;
        (current.wire_received < wire_size).then_some(wire_size - current.wire_received)
    }

    fn direct_data(
        &mut self,
        data: &[u8],
        on_event: &mut impl FnMut(BackupEvent),
    ) -> Result<(), BackupError> {
        let mbc2_save = self.mbc2_save;
        let current = self
            .current
            .as_mut()
            .ok_or_else(|| BackupError::Protocol("binary data without BEGIN".into()))?;
        let wire_size = current.expected_size.div_ceil(DIRECT_BLOCK_SIZE) * DIRECT_BLOCK_SIZE;
        if data.is_empty() || current.wire_received + data.len() as u64 > wire_size {
            return Err(BackupError::Protocol(format!(
                "unexpected direct USB data for {}",
                current.kind.protocol_name()
            )));
        }
        current.wire_received += data.len() as u64;
        let logical_remaining = current.expected_size - current.logical_received;
        let logical_len = usize::try_from(logical_remaining.min(data.len() as u64))
            .map_err(|_| BackupError::Protocol("artifact size exceeds host limits".into()))?;
        if logical_len == 0 {
            return Ok(());
        }
        if current.kind == ArtifactKind::Save && mbc2_save {
            let masked = data[..logical_len]
                .iter()
                .map(|byte| byte & 0x0f)
                .collect::<Vec<_>>();
            append(current, &masked, on_event)?;
        } else {
            append(current, &data[..logical_len], on_event)?;
        }
        Ok(())
    }

    fn encoded_data(
        &mut self,
        fields: &BTreeMap<String, String>,
        on_event: &mut impl FnMut(BackupEvent),
    ) -> Result<(), BackupError> {
        let current = self
            .current
            .as_mut()
            .ok_or_else(|| BackupError::Protocol("DATA without BEGIN".into()))?;
        if field(fields, "kind")? != current.kind.protocol_name() {
            return Err(BackupError::Protocol("DATA artifact mismatch".into()));
        }
        let sequence = parse_decimal(field(fields, "seq")?, "DATA sequence")?;
        if sequence != current.next_sequence {
            return Err(BackupError::Protocol(format!(
                "{} sequence mismatch: got {sequence}, expected {}",
                current.kind.protocol_name(),
                current.next_sequence
            )));
        }
        let declared_size = parse_decimal(field(fields, "size")?, "DATA size")?;
        let declared_crc = parse_hex_u32(field(fields, "crc")?, "DATA CRC")?;
        let data = base64::engine::general_purpose::STANDARD
            .decode(field(fields, "data")?)
            .map_err(|error| BackupError::Protocol(format!("invalid DATA encoding: {error}")))?;
        if data.len() as u64 != declared_size {
            return Err(BackupError::Protocol("DATA block-size mismatch".into()));
        }
        if crc32fast::hash(&data) != declared_crc {
            return Err(BackupError::Protocol(format!(
                "{} block CRC mismatch at sequence {sequence}",
                current.kind.protocol_name()
            )));
        }
        append(current, &data, on_event)?;
        Ok(())
    }

    fn end(
        &mut self,
        fields: &BTreeMap<String, String>,
        on_event: &mut impl FnMut(BackupEvent),
    ) -> Result<(), BackupError> {
        let mut current = self
            .current
            .take()
            .ok_or_else(|| BackupError::Protocol("END without BEGIN".into()))?;
        if field(fields, "kind")? != current.kind.protocol_name() {
            return Err(BackupError::Protocol("END artifact mismatch".into()));
        }
        let declared_size = parse_decimal(field(fields, "size")?, "final size")?;
        let declared_crc = parse_hex_u32(field(fields, "crc")?, "final CRC")?;
        if declared_size != current.logical_received || declared_size != current.expected_size {
            return Err(BackupError::Protocol(format!(
                "{} final-size mismatch",
                current.kind.protocol_name()
            )));
        }
        let actual_crc = current.crc.finalize();
        if declared_crc != actual_crc {
            return Err(BackupError::Protocol(format!(
                "{} final CRC mismatch: received {actual_crc:08x}, device reported {declared_crc:08x}",
                current.kind.protocol_name(),
            )));
        }
        if let Some(validator) = current.rom_validator {
            validator.validate()?;
        }
        current.temp.as_file_mut().flush()?;
        current.temp.as_file().sync_all()?;

        let kind = current.kind;
        let final_path = self
            .requested_outputs
            .get(&kind)
            .cloned()
            .ok_or_else(|| BackupError::Protocol("missing artifact output".into()))?;
        self.completed.insert(
            kind,
            CompletedArtifact {
                final_path,
                temp: current.temp,
            },
        );
        on_event(BackupEvent::ArtifactVerified {
            kind,
            size: declared_size,
            crc32: format!("{actual_crc:08x}"),
        });
        Ok(())
    }

    fn publish(
        &mut self,
        on_event: &mut impl FnMut(BackupEvent),
    ) -> Result<BTreeMap<ArtifactKind, PathBuf>, BackupError> {
        if self.current.is_some() {
            return Err(BackupError::Protocol(
                "device reported PASS during an artifact".into(),
            ));
        }
        let missing = self
            .requested_outputs
            .keys()
            .filter(|kind| !self.completed.contains_key(kind))
            .map(|kind| kind.protocol_name())
            .collect::<Vec<_>>();
        if !missing.is_empty() {
            return Err(BackupError::Protocol(format!(
                "device omitted requested data: {}",
                missing.join(", ")
            )));
        }

        let mut published = BTreeMap::new();
        for (kind, artifact) in std::mem::take(&mut self.completed) {
            let final_path = artifact.final_path;
            let persisted = if self.force {
                artifact.temp.persist(&final_path)
            } else {
                artifact.temp.persist_noclobber(&final_path)
            };
            let file = persisted.map_err(|error| {
                if error.error.kind() == io::ErrorKind::AlreadyExists {
                    BackupError::OutputExists(final_path.clone())
                } else {
                    BackupError::Io(error.error)
                }
            })?;
            file.sync_all()?;
            #[cfg(unix)]
            sync_parent(&final_path)?;
            published.insert(kind, final_path.clone());
            on_event(BackupEvent::ArtifactSaved {
                kind,
                path: final_path,
            });
        }
        Ok(published)
    }

    fn cleanup(&mut self) {
        self.current.take();
        self.completed.clear();
    }
}

fn append(
    current: &mut PendingArtifact,
    data: &[u8],
    on_event: &mut impl FnMut(BackupEvent),
) -> Result<(), BackupError> {
    if current.logical_received + data.len() as u64 > current.expected_size {
        return Err(BackupError::Protocol(format!(
            "too much {} data",
            current.kind.protocol_name()
        )));
    }
    current.temp.as_file_mut().write_all(data)?;
    current.crc.update(data);
    if let Some(validator) = &mut current.rom_validator {
        validator.update(data);
    }
    current.logical_received += data.len() as u64;
    current.next_sequence += 1;
    let percent = current
        .logical_received
        .saturating_mul(100)
        .checked_div(current.expected_size)
        .and_then(|value| u8::try_from(value).ok())
        .unwrap_or(100);
    if current.last_percent != Some(percent) {
        current.last_percent = Some(percent);
        on_event(BackupEvent::Progress {
            kind: current.kind,
            received: current.logical_received,
            total: current.expected_size,
            percent,
        });
    }
    Ok(())
}

fn field<'a>(fields: &'a BTreeMap<String, String>, name: &str) -> Result<&'a str, BackupError> {
    fields
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| BackupError::Protocol(format!("missing {name} field")))
}

fn parse_kind(value: &str) -> Result<ArtifactKind, BackupError> {
    match value {
        "rom" => Ok(ArtifactKind::Rom),
        "sav" => Ok(ArtifactKind::Save),
        "rtc" => Ok(ArtifactKind::Rtc),
        _ => Err(BackupError::Protocol(format!(
            "unknown artifact kind {value:?}"
        ))),
    }
}

fn parse_decimal(value: &str, name: &str) -> Result<u64, BackupError> {
    value
        .parse()
        .map_err(|_| BackupError::Protocol(format!("invalid {name}: {value:?}")))
}

fn parse_hex_u8(value: &str, name: &str) -> Result<u8, BackupError> {
    u8::from_str_radix(value.trim_start_matches("0x"), 16)
        .map_err(|_| BackupError::Protocol(format!("invalid {name}: {value:?}")))
}

fn parse_hex_u32(value: &str, name: &str) -> Result<u32, BackupError> {
    u32::from_str_radix(value.trim_start_matches("0x"), 16)
        .map_err(|_| BackupError::Protocol(format!("invalid {name}: {value:?}")))
}

fn decode_title(value: &str, color: bool) -> Result<String, BackupError> {
    let bytes = hex::decode(value)
        .map_err(|error| BackupError::Protocol(format!("invalid title encoding: {error}")))?;
    Ok(rom::header_title(&bytes, color))
}

fn absolute_path(path: &Path) -> Result<PathBuf, BackupError> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn create_part(final_path: &Path) -> Result<NamedTempFile, BackupError> {
    let file_name = final_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("backup");
    let parent = final_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    TempFileBuilder::new()
        .prefix(&format!(".{file_name}.chromatic-"))
        .suffix(".part")
        .tempfile_in(parent)
        .map_err(BackupError::Io)
}

#[cfg(unix)]
fn sync_parent(path: &Path) -> Result<(), BackupError> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        File::open(parent)?.sync_all()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_is_decoded_and_trimmed() {
        assert_eq!(
            decode_title("504f4b454d4f4e2052454400", false).unwrap(),
            "POKEMON RED"
        );
    }

    #[test]
    fn transfer_identity_matches_discovery_for_long_color_titles() {
        for (title, color, expected) in [
            ("POKEMON_GLDAAUE", true, "POKEMON_GLD"),
            ("POKEMON YELLOW", true, "POKEMON YEL"),
            ("PM_CRYSTAL", true, "PM_CRYSTAL"),
            ("SUPER MARIOLAND", false, "SUPER MARIOLAND"),
        ] {
            let mut rom = rom::tests::valid_rom();
            rom[0x134..0x144].fill(0);
            rom[0x134..0x134 + title.len()].copy_from_slice(title.as_bytes());
            rom[0x143] = if color { 0x80 } else { 0 };
            rom[0x14d] = rom[0x134..0x14d]
                .iter()
                .fold(0_u8, |sum, byte| sum.wrapping_sub(*byte).wrapping_sub(1));
            let discovery = rom::inspect_header(&rom).unwrap();
            assert_eq!(discovery.title, expected);
            for protocol in ["1", "2"] {
                let fields = BTreeMap::from([
                    ("protocol".into(), protocol.into()),
                    ("transport".into(), "usb-bulk".into()),
                    ("title".into(), hex::encode(title)),
                    ("type".into(), "10".into()),
                    ("color".into(), u8::from(color).to_string()),
                    ("rom".into(), "2097152".into()),
                    ("sav".into(), "32768".into()),
                    ("rtc".into(), "1".into()),
                ]);
                let transfer = parse_cartridge_info(&fields, protocol).unwrap();
                assert_eq!(
                    transfer.title, discovery.title,
                    "protocol {protocol}: {title}"
                );
            }
        }
    }

    #[test]
    fn protocol_marker_is_found_after_non_utf8_boundary_noise() {
        let line = b"\xff\x00PCBACKUP END kind=rom size=32768 crc=12345678\r";
        let prefix = find_subslice(line, b"PCBACKUP ").unwrap();
        let text = std::str::from_utf8(&line[prefix..]).unwrap();
        assert!(matches!(
            parse_record(text.trim_end()).unwrap(),
            Record::End(_)
        ));
    }

    #[test]
    fn unique_part_file_does_not_replace_existing_data() {
        let directory = tempfile::tempdir().unwrap();
        let final_path = directory.path().join("game.gb");
        fs::write(&final_path, b"old").unwrap();
        let mut part = create_part(&final_path).unwrap();
        part.write_all(b"new").unwrap();
        assert_eq!(fs::read(&final_path).unwrap(), b"old");
        assert_eq!(fs::read(part.path()).unwrap(), b"new");
    }

    #[test]
    fn mbc2_wire_padding_is_consumed_but_not_written() {
        let directory = tempfile::tempdir().unwrap();
        let save_path = directory.path().join("game.sav");
        let request = BackupRequest {
            save_path: Some(save_path.clone()),
            ..BackupRequest::default()
        };
        let mut receiver = Receiver::new(&request);
        receiver.mbc2_save = true;
        receiver.cartridge = Some(CartridgeInfo {
            title: "MBC2 TEST".into(),
            cartridge_type: 0x06,
            color: false,
            rom_size: 32 * 1024,
            save_size: 512,
            has_rtc: false,
        });
        receiver
            .requested_outputs
            .insert(ArtifactKind::Save, save_path);
        let fields = BTreeMap::from([("kind".into(), "sav".into()), ("size".into(), "512".into())]);
        receiver.begin(&fields, &mut |_| {}).unwrap();
        receiver
            .direct_data(&vec![0xab; 1024], &mut |_| {})
            .unwrap();
        let current = receiver.current.as_ref().unwrap();
        assert_eq!(current.logical_received, 512);
        assert_eq!(current.wire_received, 1024);
        let part_path = current.temp.path().to_path_buf();
        receiver
            .current
            .as_mut()
            .unwrap()
            .temp
            .as_file_mut()
            .flush()
            .unwrap();
        assert_eq!(fs::read(part_path).unwrap(), vec![0x0b; 512]);
    }

    #[test]
    fn save_request_derives_and_publishes_rtc_sidecar() {
        let directory = tempfile::tempdir().unwrap();
        let save_path = directory.path().join("clock.sav");
        let rtc_path = directory.path().join("clock.rtc");
        let request = BackupRequest {
            save_path: Some(save_path),
            ..BackupRequest::default()
        };
        let mut receiver = Receiver::new(&request);
        let info = BTreeMap::from([
            ("protocol".into(), "2".into()),
            ("transport".into(), "usb-bulk".into()),
            ("title".into(), "434c4f434b".into()),
            ("type".into(), "0f".into()),
            ("color".into(), "0".into()),
            ("rom".into(), "32768".into()),
            ("sav".into(), "0".into()),
            ("rtc".into(), "1".into()),
        ]);
        receiver.configure(&info, &mut |_| {}).unwrap();
        receiver
            .begin(
                &BTreeMap::from([("kind".into(), "rtc".into()), ("size".into(), "4".into())]),
                &mut |_| {},
            )
            .unwrap();
        let rtc = [1_u8, 2, 3, 4];
        receiver
            .encoded_data(
                &BTreeMap::from([
                    ("kind".into(), "rtc".into()),
                    ("seq".into(), "0".into()),
                    ("size".into(), "4".into()),
                    ("crc".into(), format!("{:08x}", crc32fast::hash(&rtc))),
                    (
                        "data".into(),
                        base64::engine::general_purpose::STANDARD.encode(rtc),
                    ),
                ]),
                &mut |_| {},
            )
            .unwrap();
        receiver
            .end(
                &BTreeMap::from([
                    ("kind".into(), "rtc".into()),
                    ("size".into(), "4".into()),
                    ("crc".into(), format!("{:08x}", crc32fast::hash(&rtc))),
                ]),
                &mut |_| {},
            )
            .unwrap();
        let outputs = receiver.publish(&mut |_| {}).unwrap();
        assert_eq!(outputs[&ArtifactKind::Rtc], rtc_path);
        assert_eq!(fs::read(rtc_path).unwrap(), rtc);
    }

    #[test]
    fn save_import_includes_same_stem_rtc_sidecar() {
        let directory = tempfile::tempdir().unwrap();
        let save_path = directory.path().join("clock.sav");
        let rtc_path = directory.path().join("clock.rtc");
        fs::write(&save_path, [0x5a; 32]).unwrap();
        fs::write(&rtc_path, 1_u32.to_le_bytes()).unwrap();

        let files = read_import_files(&save_path, false).unwrap();
        assert_eq!(files.save, [0x5a; 32]);
        assert_eq!(files.rtc_path, rtc_path);
        assert_eq!(files.rtc.unwrap(), 1_u32.to_le_bytes());
    }

    #[test]
    fn save_import_rejects_malformed_same_stem_rtc_sidecar() {
        let directory = tempfile::tempdir().unwrap();
        let save_path = directory.path().join("clock.sav");
        fs::write(&save_path, [0x5a; 32]).unwrap();
        fs::write(save_path.with_extension("rtc"), [0; 3]).unwrap();

        assert!(matches!(
            read_import_files(&save_path, false),
            Err(BackupError::InvalidSave(_))
        ));
        let files = read_import_files(&save_path, true).unwrap();
        assert_eq!(files.save, [0x5a; 32]);
        assert!(files.rtc.is_none());
        assert_eq!(fs::read(save_path.with_extension("rtc")).unwrap(), [0; 3]);
    }

    #[test]
    fn save_import_requires_physical_rtc_confirmation_before_write() {
        let save = vec![0_u8; 32768];
        let rtc = 1_u32.to_le_bytes();
        let mut importer = SaveImporter {
            save: &save,
            rtc: Some(&rtc),
            cartridge: None,
            write_started: false,
        };
        let fields = BTreeMap::from([
            ("protocol".into(), "1".into()),
            ("transport".into(), "usb-bulk".into()),
            ("title".into(), "474f4c44".into()),
            ("type".into(), "10".into()),
            ("color".into(), "1".into()),
            ("rom".into(), "2097152".into()),
            ("sav".into(), "32768".into()),
            ("rtc".into(), "0".into()),
        ]);
        assert!(matches!(
            importer.info(&fields, &mut |_| {}),
            Err(BackupError::InvalidSave(_))
        ));
        assert!(!importer.write_started);
        importer.rtc = None;
        importer.info(&fields, &mut |_| {}).unwrap();
    }
}
