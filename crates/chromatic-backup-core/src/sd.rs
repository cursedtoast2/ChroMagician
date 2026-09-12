//! SD files over the existing CF01 upload and QSPI/USB bulk download transports.
use crate::{
    BackupError, RomWriteRequest, open_chromatic, read_exact_until, read_line_until, write_upload,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use serialport::SerialPort;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SdEntry {
    pub name: String,
    pub directory: bool,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SdStatus {
    pub present: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub enum SdOperation {
    Status,
    List(String),
    Rename {
        from: String,
        to: String,
    },
    Mkdir(String),
    Delete(String),
    DeleteTree(String),
    MoveMany {
        paths: Vec<String>,
        destination: String,
    },
    DeleteMany(Vec<String>),
    Download {
        remote: String,
        local: PathBuf,
        overwrite: bool,
    },
    Upload {
        local: PathBuf,
        remote: String,
    },
    Import {
        sources: Vec<PathBuf>,
        destination: String,
    },
    InitializeBackups,
    Backup {
        remote: String,
        save: bool,
    },
}

struct Session<'a> {
    port: &'a mut dyn SerialPort,
    sequence: u32,
    deadline: Instant,
}

impl<'a> Session<'a> {
    fn start(port: &'a mut dyn SerialPort, timeout: Duration) -> Result<Self, BackupError> {
        write!(port, "\rpcsd\r")?;
        port.flush()?;
        let mut session = Self {
            port,
            sequence: 0,
            deadline: Instant::now() + timeout,
        };
        if session.record()? != "READY protocol=1 block=1024" {
            return Err(BackupError::Protocol(
                "unsupported SD firmware handshake".into(),
            ));
        }
        Ok(session)
    }
    fn record(&mut self) -> Result<String, BackupError> {
        while let Some(line) = read_line_until(self.port, self.deadline)? {
            if let Some(pos) = crate::find_subslice(&line, b"PCSD ") {
                let text = std::str::from_utf8(&line[pos + 5..])
                    .map_err(|_| BackupError::Protocol("invalid SD response".into()))?
                    .trim();
                if let Some(error) = text.strip_prefix("FAIL error=") {
                    return Err(BackupError::Device(format!("SD card: {error}")));
                }
                return Ok(text.to_owned());
            }
        }
        Err(BackupError::Timeout)
    }
    fn send(&mut self, payload: &[u8]) -> Result<(), BackupError> {
        write_upload(self.port, &crate::flash::frame(self.sequence, payload)?)?;
        Ok(())
    }
    fn ok(&mut self) -> Result<(), BackupError> {
        if self.record()? != format!("OK seq={}", self.sequence) {
            return Err(BackupError::Protocol(
                "SD response sequence mismatch".into(),
            ));
        }
        self.sequence = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| BackupError::Protocol("SD sequence overflow".into()))?;
        Ok(())
    }
    fn exchange(&mut self, payload: &[u8]) -> Result<(), BackupError> {
        self.send(payload)?;
        self.ok()
    }
    fn finish(mut self) -> Result<(), BackupError> {
        self.exchange(&[0])?;
        if self.record()? != "PASS error=ESP_OK" {
            return Err(BackupError::Protocol("SD session did not finish".into()));
        }
        Ok(())
    }
    fn list(&mut self, path: &str) -> Result<Vec<SdEntry>, BackupError> {
        self.send(&path_payload(2, path)?)?;
        let mut entries = Vec::new();
        loop {
            let record = self.record()?;
            if let Some(data) = record.strip_prefix("ENTRY ") {
                let entry: SdEntry = serde_json::from_str(data)
                    .map_err(|_| BackupError::Protocol("invalid SD directory entry".into()))?;
                if entry.name.is_empty()
                    || entry.name.contains(['/', '\\', '\0'])
                    || entry.name == "."
                    || entry.name == ".."
                {
                    return Err(BackupError::Protocol("invalid SD entry name".into()));
                }
                entries.push(entry);
            } else if record == format!("OK seq={}", self.sequence) {
                self.sequence += 1;
                break;
            } else {
                return Err(BackupError::Protocol("invalid SD listing".into()));
            }
        }
        entries.sort_by(|a, b| {
            b.directory
                .cmp(&a.directory)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(entries)
    }
    fn delete_tree(&mut self, root: &str) -> Result<(), BackupError> {
        let removals = self.tree_removals(root)?;
        for path in removals {
            self.exchange(&path_payload(5, &path)?)?;
        }
        Ok(())
    }
    fn tree_removals(&mut self, root: &str) -> Result<Vec<String>, BackupError> {
        validate_path(root)?;
        if root == "/" {
            return Err(BackupError::Protocol("cannot delete the SD root".into()));
        }
        let mut folders = vec![root.to_owned()];
        let mut removals = Vec::new();
        while let Some(folder) = folders.pop() {
            for entry in self.list(&folder)? {
                let path = format!("{folder}/{}", entry.name);
                validate_path(&path)?;
                if entry.directory {
                    folders.push(path);
                } else {
                    removals.push(path);
                }
            }
            removals.push(folder);
        }
        removals.sort_by_key(|path| std::cmp::Reverse(path.len()));
        Ok(removals)
    }

    fn batch(&mut self, paths: &[String], destination: Option<&str>) -> Result<(), BackupError> {
        let parent = selection_parent(paths)?;
        let entries = self.list(parent)?;
        let mut selected = Vec::new();
        for path in paths {
            let name = path.rsplit('/').next().expect("validated path");
            let entry = entries
                .iter()
                .find(|entry| entry.name == name)
                .ok_or_else(|| {
                    BackupError::Protocol(format!("{name} is no longer in this folder."))
                })?;
            selected.push((path, entry));
        }
        if let Some(destination) = destination {
            validate_path(destination)?;
            let destination_key = destination.to_lowercase();
            if destination_key == parent.to_lowercase()
                || paths.iter().any(|path| {
                    let key = path.to_lowercase();
                    destination_key == key || destination_key.starts_with(&format!("{key}/"))
                })
            {
                return Err(BackupError::Protocol(
                    "Choose a different destination folder.".into(),
                ));
            }
            let existing = self.list(destination)?;
            let mut moves = Vec::new();
            for (path, entry) in selected {
                if existing
                    .iter()
                    .any(|other| other.name.to_lowercase() == entry.name.to_lowercase())
                {
                    return Err(BackupError::Protocol(format!(
                        "{} already exists in the destination folder.",
                        entry.name
                    )));
                }
                let target = format!("{}/{}", destination.trim_end_matches('/'), entry.name);
                validate_path(&target)?;
                let mut payload = path_payload(3, path)?;
                payload.push(0);
                payload.extend(target.as_bytes());
                if payload.len() > 1536 {
                    return Err(BackupError::Protocol(
                        "The destination path is too long.".into(),
                    ));
                }
                moves.push(payload);
            }
            for payload in moves {
                self.exchange(&payload)?;
            }
        } else {
            let mut removals = Vec::new();
            for (path, entry) in selected {
                if entry.directory {
                    removals.extend(self.tree_removals(path)?);
                } else {
                    removals.push(path.clone());
                }
            }
            for path in removals {
                self.exchange(&path_payload(5, &path)?)?;
            }
        }
        Ok(())
    }
    fn ensure_directory(&mut self, path: &str) -> Result<(), BackupError> {
        let (parent, name) = path.rsplit_once('/').expect("absolute directory path");
        let entries = self.list(if parent.is_empty() { "/" } else { parent })?;
        if let Some(entry) = entries
            .iter()
            .find(|entry| entry.name.eq_ignore_ascii_case(name))
        {
            if !entry.directory {
                return Err(BackupError::Protocol(
                    "The backup destination is not a folder.".into(),
                ));
            }
        } else {
            self.exchange(&path_payload(4, path)?)?;
        }
        Ok(())
    }
    fn upload(
        &mut self,
        remote: &str,
        input: &mut (std::fs::File, u32, u32),
        event: &mut impl FnMut(Value),
    ) -> Result<(), BackupError> {
        validate_path(remote)?;
        let (file, size, crc) = input;
        let mut payload = vec![7];
        payload.extend(size.to_le_bytes());
        payload.extend(crc.to_le_bytes());
        payload.extend(remote.as_bytes());
        self.exchange(&payload)?;
        let mut sent = 0_u32;
        let mut buffer = [0; 1025];
        buffer[0] = 8;
        while sent < *size {
            let count = usize::try_from((*size - sent).min(1024)).expect("bounded block");
            file.read_exact(&mut buffer[1..=count])?;
            self.exchange(&buffer[..=count])?;
            sent += u32::try_from(count).expect("bounded block");
            event(json!({"event":"progress", "phase":"sd_write", "completed":sent, "total":size}));
        }
        event(json!({"event":"progress", "phase":"verify", "completed":0, "total":size}));
        self.exchange(&[9])
    }
    fn import(
        &mut self,
        destination: &str,
        items: &[ImportItem],
        timeout: Duration,
        event: &mut impl FnMut(Value),
    ) -> Result<(), BackupError> {
        let existing = self.list(destination)?;
        for item in items {
            let (parent, name) = item.remote.rsplit_once('/').expect("validated path");
            if parent == destination.trim_end_matches('/')
                && existing
                    .iter()
                    .any(|entry| entry.name.to_lowercase() == name.to_lowercase())
            {
                return Err(BackupError::Protocol(format!(
                    "{name} already exists in the destination folder."
                )));
            }
        }
        let total: u64 = items
            .iter()
            .filter_map(|item| item.upload.map(|(size, _)| u64::from(size)))
            .sum();
        let mut completed = 0_u64;
        event(json!({"event":"progress", "phase":"sd_write", "completed":0, "total":total}));
        for item in items {
            if let Some((size, crc)) = item.upload {
                let file = std::fs::File::open(&item.local)?;
                if file.metadata()?.len() != u64::from(size) {
                    return Err(BackupError::Protocol(format!(
                        "{} changed during the import.",
                        item.local.display()
                    )));
                }
                let mut input = (file, size, crc);
                self.deadline = Instant::now() + timeout;
                self.upload(&item.remote, &mut input, &mut |progress| {
                    if progress["phase"] == "sd_write" {
                        let sent = progress["completed"].as_u64().expect("upload progress");
                        event(json!({"event":"progress", "phase":"sd_write", "completed":completed + sent, "total":total}));
                    }
                })?;
                completed += u64::from(size);
            } else {
                self.exchange(&path_payload(4, &item.remote)?)?;
            }
        }
        Ok(())
    }
    fn backup(
        &mut self,
        remote: &str,
        save: bool,
        event: &mut impl FnMut(Value),
    ) -> Result<Vec<String>, BackupError> {
        validate_path(remote)?;
        let (parent, _) = remote.rsplit_once('/').expect("validated absolute path");
        let parent = if parent.is_empty() { "/" } else { parent };
        if parent == "/CHROMAGIC/BACKUPS" {
            self.ensure_directory("/CHROMAGIC")?;
            self.ensure_directory(parent)?;
        }
        let remote = backup_path(remote, save)?;
        self.send(&path_payload(if save { 11 } else { 10 }, &remote)?)?;
        let mut saved = Vec::new();
        loop {
            let record = self.record()?;
            if let Some(progress) = record
                .strip_prefix("PROGRESS ")
                .or_else(|| record.strip_prefix("VERIFY "))
            {
                let fields: Vec<_> = progress.split_whitespace().collect();
                let completed = fields
                    .first()
                    .and_then(|v| v.strip_prefix("completed="))
                    .and_then(|v| v.parse::<u64>().ok());
                let total = fields
                    .get(1)
                    .and_then(|v| v.strip_prefix("total="))
                    .and_then(|v| v.parse::<u64>().ok());
                let (Some(completed), Some(total)) = (completed, total) else {
                    return Err(BackupError::Protocol("invalid SD backup progress".into()));
                };
                if completed > total {
                    return Err(BackupError::Protocol("invalid SD backup progress".into()));
                }
                let phase = if record.starts_with("VERIFY ") {
                    "sd_verify"
                } else {
                    "sd_backup"
                };
                event(
                    json!({"event":"progress", "phase":phase, "completed":completed, "total":total}),
                );
            } else if let Some(path) = record.strip_prefix("SAVED ") {
                let stem = remote
                    .rsplit_once('.')
                    .expect("validated backup extension")
                    .0;
                if path != remote
                    && path != format!("{stem}.rtc")
                    && (save || path != format!("{stem}.sav"))
                {
                    return Err(BackupError::Protocol("unexpected SD backup path".into()));
                }
                saved.push(path.to_owned());
            } else if record == format!("OK seq={}", self.sequence) {
                self.sequence += 1;
                if saved.is_empty() {
                    return Err(BackupError::Protocol("SD backup produced no files".into()));
                }
                return Ok(saved);
            } else {
                return Err(BackupError::Protocol("invalid SD backup response".into()));
            }
        }
    }
    fn download(
        &mut self,
        remote: &str,
        local: &std::path::Path,
        event: &mut impl FnMut(Value),
    ) -> Result<tempfile::NamedTempFile, BackupError> {
        let parent = local
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| std::path::Path::new("."));
        let mut output = tempfile::NamedTempFile::new_in(parent)?;
        self.send(&path_payload(6, remote)?)?;
        let header = self.record()?;
        let size: u64 = header
            .strip_prefix("BULK size=")
            .and_then(|v| v.parse().ok())
            .filter(|v| u32::try_from(*v).is_ok())
            .ok_or_else(|| BackupError::Protocol("invalid SD download size".into()))?;
        let mut received = 0;
        let mut crc = crc32fast::Hasher::new();
        while received < size {
            let bytes = read_exact_until(self.port, 1024, self.deadline)?;
            let count = usize::try_from((size - received).min(1024)).expect("bounded block");
            output.write_all(&bytes[..count])?;
            crc.update(&bytes[..count]);
            received += count as u64;
            event(
                json!({"event":"progress", "phase":"sd_read", "completed":received, "total":size}),
            );
        }
        let record = self.record()?;
        let expected = record
            .strip_prefix("CRC crc=")
            .and_then(|v| u32::from_str_radix(v, 16).ok())
            .ok_or_else(|| BackupError::Protocol("missing SD checksum".into()))?;
        if crc.finalize() != expected {
            return Err(BackupError::Protocol(
                "SD download checksum mismatch".into(),
            ));
        }
        self.ok()?;
        Ok(output)
    }
    fn status(&mut self) -> Result<SdStatus, BackupError> {
        self.send(&[1])?;
        let status = parse_status(&self.record()?)?;
        self.ok()?;
        Ok(status)
    }
}

fn parse_status(record: &str) -> Result<SdStatus, BackupError> {
    let mut words = record.split_ascii_whitespace();
    if words.next() != Some("STATUS") {
        return Err(BackupError::Protocol("invalid SD status".into()));
    }
    let present = match words.next() {
        Some("present=1") => true,
        Some("present=0") => false,
        _ => return Err(BackupError::Protocol("invalid SD presence".into())),
    };
    let error = match words.next() {
        None | Some("error=ESP_OK" | "error=ESP_ERR_NOT_FOUND") => None,
        Some(value) => Some(
            value
                .strip_prefix("error=")
                .ok_or_else(|| BackupError::Protocol("invalid SD error".into()))?
                .to_owned(),
        ),
    };
    if words.next().is_some() || (present && error.is_some()) {
        return Err(BackupError::Protocol("inconsistent SD status".into()));
    }
    Ok(SdStatus { present, error })
}

pub(crate) fn status_on_port(port: &mut dyn SerialPort) -> Result<SdStatus, BackupError> {
    let mut session = Session::start(port, Duration::from_secs(3))?;
    let present = session.status()?;
    session.finish()?;
    Ok(present)
}

#[allow(clippy::missing_errors_doc)]
pub fn list_sd_on_port(port: &mut dyn SerialPort, path: &str) -> Result<Vec<SdEntry>, BackupError> {
    validate_path(path)?;
    let mut session = Session::start(port, Duration::from_secs(30))?;
    let entries = session.list(path)?;
    session.finish()?;
    Ok(entries)
}

fn path_payload(op: u8, path: &str) -> Result<Vec<u8>, BackupError> {
    validate_path(path)?;
    let mut payload = vec![op];
    payload.extend(path.as_bytes());
    Ok(payload)
}

fn validate_path(path: &str) -> Result<(), BackupError> {
    if !path.starts_with('/')
        || path.len() >= 760
        || (path != "/"
            && path[1..].split('/').any(|part| {
                part.is_empty()
                    || part.len() > 255
                    || part.ends_with(['.', ' '])
                    || part
                        .chars()
                        .any(|c| c.is_control() || "\\:*?\"<>|".contains(c))
            }))
    {
        return Err(BackupError::Protocol("invalid SD path".into()));
    }
    Ok(())
}

fn selection_parent(paths: &[String]) -> Result<&str, BackupError> {
    let mut parent = None;
    let mut seen = std::collections::HashSet::new();
    for path in paths {
        validate_path(path)?;
        let (folder, _) = path.rsplit_once('/').expect("validated absolute path");
        let folder = if folder.is_empty() { "/" } else { folder };
        if path == "/"
            || parent.is_some_and(|parent| parent != folder)
            || !seen.insert(path.to_lowercase())
        {
            return Err(BackupError::Protocol(
                "Select distinct items from one folder.".into(),
            ));
        }
        parent = Some(folder);
    }
    parent.ok_or_else(|| BackupError::Protocol("Select at least one item.".into()))
}

struct ImportItem {
    local: PathBuf,
    remote: String,
    upload: Option<(u32, u32)>,
}

fn import_items(sources: &[PathBuf], destination: &str) -> Result<Vec<ImportItem>, BackupError> {
    validate_path(destination)?;
    let mut pending = Vec::new();
    for local in sources.iter().rev() {
        let name = local
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| {
                BackupError::Protocol("Choose a file or folder with a valid name.".into())
            })?;
        pending.push((
            local.clone(),
            format!("{}/{name}", destination.trim_end_matches('/')),
        ));
    }
    let mut items = Vec::new();
    let mut names = std::collections::HashSet::new();
    while let Some((local, remote)) = pending.pop() {
        validate_path(&remote)?;
        if !names.insert(remote.to_lowercase()) {
            return Err(BackupError::Protocol(format!(
                "Duplicate SD name: {remote}"
            )));
        }
        let metadata = std::fs::symlink_metadata(&local)?;
        let upload = if metadata.is_file() {
            let (_, size, crc) = open_upload(&local)?;
            Some((size, crc))
        } else if metadata.is_dir() {
            let mut children = std::fs::read_dir(&local)?.collect::<Result<Vec<_>, _>>()?;
            children.sort_by_key(std::fs::DirEntry::file_name);
            for child in children.into_iter().rev() {
                let name = child.file_name().into_string().map_err(|_| {
                    BackupError::Protocol("A file name cannot be stored on the SD card.".into())
                })?;
                pending.push((child.path(), format!("{remote}/{name}")));
            }
            None
        } else {
            return Err(BackupError::Protocol(format!(
                "Cannot import a link or special file: {}",
                local.display()
            )));
        };
        items.push(ImportItem {
            local,
            remote,
            upload,
        });
    }
    if items.is_empty() {
        return Err(BackupError::Protocol(
            "Select at least one file or folder.".into(),
        ));
    }
    Ok(items)
}

fn open_upload(local: &std::path::Path) -> Result<(std::fs::File, u32, u32), BackupError> {
    let mut file = std::fs::File::open(local)?;
    let size = u32::try_from(file.metadata()?.len())
        .map_err(|_| BackupError::Protocol("file exceeds FAT size limit".into()))?;
    let mut crc = crc32fast::Hasher::new();
    let mut buffer = [0; 8192];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        crc.update(&buffer[..n]);
    }
    std::io::Seek::rewind(&mut file)?;
    Ok((file, size, crc.finalize()))
}

/// Manage SD files through `ChroMagician` firmware. Existing SD names are preserved.
/// # Errors
/// Returns filesystem, transport, or checksum failures; incomplete uploads are removed.
#[allow(clippy::too_many_lines, clippy::missing_panics_doc)]
pub fn sd_files(
    request: &RomWriteRequest,
    operation: &SdOperation,
    mut event: impl FnMut(Value),
) -> Result<(), BackupError> {
    match operation {
        SdOperation::MoveMany { paths, destination } => {
            selection_parent(paths)?;
            validate_path(destination)?;
        }
        SdOperation::DeleteMany(paths) => {
            selection_parent(paths)?;
        }
        _ => {}
    }
    let mut input = if let SdOperation::Upload { local, .. } = operation {
        Some(open_upload(local)?)
    } else {
        None
    };
    let imports = if let SdOperation::Import {
        sources,
        destination,
    } = operation
    {
        import_items(sources, destination)?
    } else {
        Vec::new()
    };
    event(json!({"event":"session_started", "schema_version":1}));
    let (_, mut port) = open_chromatic(request.port.as_deref(), request.boot_wait)?;
    let mut session = Session::start(&mut *port, request.timeout)?;
    let mut saved = Vec::new();
    match operation {
        SdOperation::Status => {
            let status = session.status()?;
            event(json!({"event":"sd_status", "present":status.present, "error":status.error}));
        }
        SdOperation::List(path) => {
            let entries = session.list(path)?;
            event(json!({"event":"sd_list", "path":path, "entries":entries}));
        }
        SdOperation::Rename { from, to } => {
            let mut payload = path_payload(3, from)?;
            validate_path(to)?;
            payload.push(0);
            payload.extend(to.as_bytes());
            session.exchange(&payload)?;
        }
        SdOperation::Mkdir(path) => session.exchange(&path_payload(4, path)?)?,
        SdOperation::InitializeBackups => {
            session.ensure_directory("/CHROMAGIC")?;
            session.ensure_directory("/CHROMAGIC/BACKUPS")?;
        }
        SdOperation::Import { destination, .. } => {
            session.import(destination, &imports, request.timeout, &mut event)?;
        }
        SdOperation::Delete(path) => session.exchange(&path_payload(5, path)?)?,
        SdOperation::DeleteTree(path) => session.delete_tree(path)?,
        SdOperation::MoveMany { paths, destination } => session.batch(paths, Some(destination))?,
        SdOperation::DeleteMany(paths) => session.batch(paths, None)?,
        SdOperation::Backup { remote, save } => {
            saved = session.backup(remote, *save, &mut event)?;
        }
        SdOperation::Download {
            remote,
            local,
            overwrite,
        } => {
            if !overwrite && local.exists() {
                return Err(BackupError::Protocol("output file already exists".into()));
            }
            let output = session.download(remote, local, &mut event)?;
            session.finish()?;
            output.as_file().sync_all()?;
            let result = if *overwrite {
                output.persist(local)
            } else {
                output.persist_noclobber(local)
            };
            result.map_err(|e| BackupError::Io(e.error))?;
            event(json!({"event":"file_saved", "path":local}));
            event(json!({"event":"complete", "operation":"sd"}));
            return Ok(());
        }
        SdOperation::Upload { remote, .. } => {
            session.upload(remote, input.as_mut().expect("opened upload"), &mut event)?;
        }
    }
    let changed = match operation {
        SdOperation::MoveMany { paths, .. } | SdOperation::DeleteMany(paths) => paths.first(),
        SdOperation::Rename { from, .. }
        | SdOperation::Mkdir(from)
        | SdOperation::Delete(from)
        | SdOperation::DeleteTree(from) => Some(from),
        SdOperation::Upload { remote, .. } | SdOperation::Backup { remote, .. } => Some(remote),
        _ => None,
    };
    let listing = match operation {
        SdOperation::InitializeBackups => Some("/CHROMAGIC/BACKUPS"),
        SdOperation::Import { destination, .. } => Some(destination.as_str()),
        _ => changed.map(|path| {
            path.rsplit_once('/').map_or(
                "/",
                |(parent, _)| if parent.is_empty() { "/" } else { parent },
            )
        }),
    };
    if let Some(parent) = listing {
        let entries = session.list(parent)?;
        event(json!({"event":"sd_list", "path":parent, "entries":entries}));
    }
    session.finish()?;
    for path in saved {
        event(json!({"event":"file_saved", "path":path}));
    }
    event(json!({"event":"complete", "operation":"sd"}));
    Ok(())
}

fn backup_path(remote: &str, save: bool) -> Result<String, BackupError> {
    validate_path(remote)?;
    let (parent, name) = remote.rsplit_once('/').expect("validated absolute path");
    let (stem, extension) = name
        .rsplit_once('.')
        .ok_or_else(|| BackupError::Protocol("invalid SD backup extension".into()))?;
    if stem.is_empty()
        || (save && extension != "sav")
        || (!save && !matches!(extension, "gb" | "gbc"))
    {
        return Err(BackupError::Protocol("invalid SD backup extension".into()));
    }
    let mut end = stem.len().min(247);
    while !stem.is_char_boundary(end) {
        end -= 1;
    }
    Ok(format!("{parent}/{}.{extension}", &stem[..end]))
}

#[cfg(test)]
mod tests {
    #[test]
    fn bulk_selection_rejects_root_duplicates_and_mixed_folders() {
        for paths in [
            vec![],
            vec!["/"],
            vec!["/a", "/A"],
            vec!["/a", "/other/b"],
            vec!["/../a"],
        ] {
            assert!(
                selection_parent(&paths.into_iter().map(str::to_owned).collect::<Vec<_>>())
                    .is_err()
            );
        }
        assert_eq!(
            selection_parent(&["/日本/a.gb".into(), "/日本/a.sav".into()]).unwrap(),
            "/日本"
        );
    }

    #[cfg(unix)]
    fn batch_script(
        script: Vec<(Vec<u8>, String)>,
        paths: &[&str],
        destination: Option<&str>,
        device_failed: bool,
    ) -> Result<(), BackupError> {
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(50)).unwrap();
        device.set_timeout(Duration::from_secs(2)).unwrap();
        let (done, wait) = std::sync::mpsc::channel();
        let peer = std::thread::spawn(move || {
            let mut command = [0; 6];
            device.read_exact(&mut command).unwrap();
            assert_eq!(&command, b"\rpcsd\r");
            device
                .write_all(b"PCSD READY protocol=1 block=1024\n")
                .unwrap();
            let mut sequence = 0;
            for (payload, response) in script {
                let expected = crate::flash::frame(sequence, &payload).unwrap();
                let mut received = vec![0; expected.len()];
                device.read_exact(&mut received).unwrap();
                assert_eq!(received, expected);
                write!(device, "{response}").unwrap();
                if !response.starts_with("PCSD FAIL") {
                    writeln!(device, "PCSD OK seq={sequence}").unwrap();
                }
                sequence += 1;
            }
            if !device_failed {
                let expected = crate::flash::frame(sequence, &[0]).unwrap();
                let mut received = vec![0; expected.len()];
                device.read_exact(&mut received).unwrap();
                assert_eq!(
                    received, expected,
                    "no unexpected mutation after the planned commands"
                );
                writeln!(device, "PCSD OK seq={sequence}\nPCSD PASS error=ESP_OK").unwrap();
            }
            wait.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        let mut session = Session::start(&mut client, Duration::from_secs(3)).unwrap();
        let result = session.batch(
            &paths.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>(),
            destination,
        );
        if !device_failed {
            session.finish().unwrap();
        }
        done.send(()).unwrap();
        peer.join().unwrap();
        result
    }

    #[cfg(unix)]
    #[test]
    fn bulk_move_reuses_rename_and_checks_all_collisions_before_mutation() {
        let source = concat!(
            "PCSD ENTRY {\"name\":\"a.gb\",\"directory\":false,\"size\":10}\n",
            "PCSD ENTRY {\"name\":\"a.sav\",\"directory\":false,\"size\":10}\n"
        );
        for collision in [false, true] {
            let mut script = vec![
                (b"\x02/".to_vec(), source.to_owned()),
                (
                    b"\x02/Games".to_vec(),
                    if collision {
                        "PCSD ENTRY {\"name\":\"A.SAV\",\"directory\":false,\"size\":20}\n".into()
                    } else {
                        String::new()
                    },
                ),
            ];
            if !collision {
                script.push((b"\x03/a.gb\0/Games/a.gb".to_vec(), String::new()));
                script.push((b"\x03/a.sav\0/Games/a.sav".to_vec(), String::new()));
            }
            let result = batch_script(script, &["/a.gb", "/a.sav"], Some("/Games"), false);
            assert_eq!(result.is_err(), collision);
        }
    }

    #[cfg(unix)]
    #[test]
    fn bulk_delete_expands_selected_folders_and_preserves_other_entries() {
        let script = vec![
            (
                b"\x02/".to_vec(),
                concat!(
                    "PCSD ENTRY {\"name\":\"Folder\",\"directory\":true,\"size\":0}\n",
                    "PCSD ENTRY {\"name\":\"a.sav\",\"directory\":false,\"size\":10}\n",
                    "PCSD ENTRY {\"name\":\"keep.gb\",\"directory\":false,\"size\":10}\n"
                )
                .into(),
            ),
            (
                b"\x02/Folder".to_vec(),
                "PCSD ENTRY {\"name\":\"game.gb\",\"directory\":false,\"size\":10}\n".into(),
            ),
            (b"\x05/Folder/game.gb".to_vec(), String::new()),
            (b"\x05/Folder".to_vec(), String::new()),
            (b"\x05/a.sav".to_vec(), String::new()),
        ];
        batch_script(script, &["/Folder", "/a.sav"], None, false).unwrap();
        let script = vec![(
            b"\x02/".to_vec(),
            "PCSD ENTRY {\"name\":\"Folder\",\"directory\":true,\"size\":0}\n".into(),
        )];
        assert!(batch_script(script, &["/Folder"], Some("/Folder/nested"), false).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn bulk_move_stops_at_a_device_failure() {
        let script = vec![
            (
                b"\x02/".to_vec(),
                ["a", "b", "c"]
                    .map(|name| {
                        format!(
                            "PCSD ENTRY {{\"name\":\"{name}\",\"directory\":false,\"size\":1}}\n"
                        )
                    })
                    .join(""),
            ),
            (b"\x02/Games".to_vec(), String::new()),
            (b"\x03/a\0/Games/a".to_vec(), String::new()),
            (
                b"\x03/b\0/Games/b".to_vec(),
                "PCSD FAIL error=ESP_FAIL\n".into(),
            ),
        ];
        assert!(batch_script(script, &["/a", "/b", "/c"], Some("/Games"), true).is_err());
    }

    #[test]
    fn sd_status_distinguishes_absence_from_mount_failure() {
        use super::*;
        for record in [
            "STATUS present=0",
            "STATUS present=0 error=ESP_ERR_NOT_FOUND",
        ] {
            assert_eq!(
                parse_status(record).unwrap(),
                SdStatus {
                    present: false,
                    error: None
                }
            );
        }
        assert_eq!(
            parse_status("STATUS present=1 error=ESP_OK").unwrap(),
            SdStatus {
                present: true,
                error: None
            }
        );
        assert_eq!(
            parse_status("STATUS present=0 error=ESP_ERR_TIMEOUT").unwrap(),
            SdStatus {
                present: false,
                error: Some("ESP_ERR_TIMEOUT".into())
            }
        );
        assert!(parse_status("STATUS present=1 error=ESP_FAIL").is_err());
    }
    use super::*;
    #[cfg(unix)]
    #[test]
    fn folder_deletion_validates_then_removes_children_before_parents() {
        for malicious in [false, true] {
            let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
            client.set_timeout(Duration::from_millis(100)).unwrap();
            device.set_timeout(Duration::from_secs(2)).unwrap();
            let peer = std::thread::spawn(move || {
                let mut command = [0; 6];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\rpcsd\r");
                device
                    .write_all(b"PCSD READY protocol=1 block=1024\n")
                    .unwrap();
                let mut sequence = 0;
                let mut expected_request = |payload: &[u8], response: &str| {
                    let expected = crate::flash::frame(sequence, payload).unwrap();
                    let mut received = vec![0; expected.len()];
                    device.read_exact(&mut received).unwrap();
                    assert_eq!(received, expected);
                    writeln!(device, "{response}PCSD OK seq={sequence}").unwrap();
                    sequence += 1;
                };
                expected_request(
                    b"\x02/CHROMATIC",
                    concat!(
                        "PCSD ENTRY {\"name\":\"game.gb\",\"directory\":false,\"size\":10}\n",
                        "PCSD ENTRY {\"name\":\"nested\",\"directory\":true,\"size\":0}\n"
                    ),
                );
                if malicious {
                    expected_request(
                        b"\x02/CHROMATIC/nested",
                        "PCSD ENTRY {\"name\":\"../outside\",\"directory\":false,\"size\":1}\n",
                    );
                    expected_request(&[0], "");
                } else {
                    expected_request(
                        b"\x02/CHROMATIC/nested",
                        "PCSD ENTRY {\"name\":\"save.sav\",\"directory\":false,\"size\":32}\n",
                    );
                    expected_request(b"\x05/CHROMATIC/nested/save.sav", "");
                    expected_request(b"\x05/CHROMATIC/game.gb", "");
                    expected_request(b"\x05/CHROMATIC/nested", "");
                    expected_request(b"\x05/CHROMATIC", "");
                    expected_request(&[0], "");
                }
                device.write_all(b"PCSD PASS error=ESP_OK\n").unwrap();
                std::thread::sleep(Duration::from_millis(100));
            });
            let mut session = Session::start(&mut client, Duration::from_secs(4)).unwrap();
            assert!(session.delete_tree("/").is_err());
            let result = session.delete_tree("/CHROMATIC");
            assert_eq!(result.is_err(), malicious);
            if malicious {
                session.ok().unwrap();
            }
            session.finish().unwrap();
            peer.join().unwrap();
        }
    }
    #[test]
    fn backup_names_keep_a_stable_stem_for_replacement_and_clock_sidecars() {
        let name = "/CHROMAGIC/BACKUPS/Pokemon - Crystal (Japan) (Rev 1).sav";
        assert_eq!(backup_path(name, true).unwrap(), name);
        assert!(backup_path(name, false).is_err());
        let long = format!("/CHROMAGIC/BACKUPS/{}.gbc", "あ".repeat(83));
        let result = backup_path(&long, false).unwrap();
        assert!(result.rsplit('/').next().unwrap().len() <= 251);
        assert_eq!(std::path::Path::new(&result).extension().unwrap(), "gbc");
    }

    #[cfg(unix)]
    #[test]
    #[allow(clippy::too_many_lines)]
    fn direct_backup_waits_for_the_complete_rom_save_and_clock_set() {
        for (save_only, fail_clock, existing_folders) in [
            (true, false, 0),
            (true, true, 1),
            (false, false, 2),
            (false, true, 0),
        ] {
            let remote = if save_only {
                "/CHROMAGIC/BACKUPS/Crystal (Japan).sav"
            } else {
                "/CHROMAGIC/BACKUPS/Crystal (Japan).gbc"
            };
            let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
            client.set_timeout(Duration::from_millis(100)).unwrap();
            device.set_timeout(Duration::from_secs(2)).unwrap();
            let peer = std::thread::spawn(move || {
                let mut command = [0; 6];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\rpcsd\r");
                device
                    .write_all(b"PCSD READY protocol=1 block=1024\n")
                    .unwrap();
                let root_entry = if existing_folders > 0 {
                    "PCSD ENTRY {\"name\":\"chromagic\",\"directory\":true,\"size\":0}\n"
                } else {
                    ""
                };
                let backup_entry = if existing_folders > 1 {
                    "PCSD ENTRY {\"name\":\"backups\",\"directory\":true,\"size\":0}\n"
                } else {
                    ""
                };
                let mut setup: Vec<(&[u8], &str)> = vec![(b"\x02/", root_entry)];
                if existing_folders == 0 {
                    setup.push((b"\x04/CHROMAGIC", ""));
                }
                setup.push((b"\x02/CHROMAGIC", backup_entry));
                if existing_folders < 2 {
                    setup.push((b"\x04/CHROMAGIC/BACKUPS", ""));
                }
                for (sequence, (request, response)) in setup.iter().enumerate() {
                    let expected =
                        crate::flash::frame(u32::try_from(sequence).unwrap(), request).unwrap();
                    let mut received = vec![0; expected.len()];
                    device.read_exact(&mut received).unwrap();
                    assert_eq!(received, expected, "create only missing backup folders");
                    writeln!(device, "{response}PCSD OK seq={sequence}").unwrap();
                }
                let sequence = u32::try_from(setup.len()).unwrap();
                let payload = path_payload(if save_only { 11 } else { 10 }, remote).unwrap();
                let expected = crate::flash::frame(sequence, &payload).unwrap();
                let mut received = vec![0; expected.len()];
                device.read_exact(&mut received).unwrap();
                assert_eq!(received, expected);
                if !save_only {
                    device
                        .write_all(b"PCSD SAVED /CHROMAGIC/BACKUPS/Crystal (Japan).gbc\n")
                        .unwrap();
                }
                device.write_all(b"PCSD PROGRESS completed=32768 total=32772\nPCSD SAVED /CHROMAGIC/BACKUPS/Crystal (Japan).sav\n").unwrap();
                if fail_clock {
                    writeln!(
                        device,
                        "PCSD FAIL error=ESP_ERR_TIMEOUT op={} errno=0",
                        if save_only { 11 } else { 10 }
                    )
                    .unwrap();
                } else {
                    writeln!(device, "PCSD PROGRESS completed=32772 total=32772\nPCSD SAVED /CHROMAGIC/BACKUPS/Crystal (Japan).rtc\nPCSD OK seq={sequence}").unwrap();
                    let mut finish = [0; 17];
                    device.read_exact(&mut finish).unwrap();
                    assert_eq!(
                        finish.to_vec(),
                        crate::flash::frame(sequence + 1, &[0]).unwrap()
                    );
                    writeln!(
                        device,
                        "PCSD OK seq={}\nPCSD PASS error=ESP_OK",
                        sequence + 1
                    )
                    .unwrap();
                }
                std::thread::sleep(Duration::from_millis(100));
            });
            let mut session = Session::start(&mut client, Duration::from_secs(3)).unwrap();
            let mut events = Vec::new();
            let result = session.backup(remote, save_only, &mut |event| {
                events.push(event);
            });
            if fail_clock {
                assert!(result.is_err());
            } else {
                let mut expected = Vec::new();
                if !save_only {
                    expected.push("/CHROMAGIC/BACKUPS/Crystal (Japan).gbc");
                }
                expected.extend([
                    "/CHROMAGIC/BACKUPS/Crystal (Japan).sav",
                    "/CHROMAGIC/BACKUPS/Crystal (Japan).rtc",
                ]);
                assert_eq!(result.unwrap(), expected);
                session.finish().unwrap();
            }
            assert!(events.iter().all(|event| event["event"] == "progress"));
            peer.join().unwrap();
        }
    }
    #[cfg(unix)]
    #[test]
    fn binary_download_checks_crc_and_preserves_exact_final_length() {
        for corrupt in [false, true] {
            let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
            client.set_timeout(Duration::from_millis(100)).unwrap();
            device.set_timeout(Duration::from_secs(2)).unwrap();
            let data: Vec<u8> = (0..2051).map(|i| u8::try_from(i % 251).unwrap()).collect();
            let expected = data.clone();
            let peer = std::thread::spawn(move || {
                let mut command = [0; 6];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\rpcsd\r");
                device
                    .write_all(b"PCSD READY protocol=1 block=1024\n")
                    .unwrap();
                let mut header = [0; 16];
                device.read_exact(&mut header).unwrap();
                let n = u32::from_le_bytes(header[8..12].try_into().unwrap());
                let mut request = vec![0; n as usize];
                device.read_exact(&mut request).unwrap();
                assert_eq!(request, b"\x06/game.gbc");
                assert_eq!(&header, &crate::flash::frame(0, &request).unwrap()[..16]);
                device.write_all(b"PCSD BULK size=2051\n").unwrap();
                device.write_all(&data).unwrap();
                device.write_all(&vec![0xff; 3072 - data.len()]).unwrap();
                writeln!(
                    device,
                    "PCSD CRC crc={:08x}",
                    crc32fast::hash(&data) ^ u32::from(corrupt)
                )
                .unwrap();
                device.write_all(b"PCSD OK seq=0\n").unwrap();
                if !corrupt {
                    let mut finish = [0; 17];
                    device.read_exact(&mut finish).unwrap();
                    assert_eq!(finish.to_vec(), crate::flash::frame(1, &[0]).unwrap());
                    device
                        .write_all(b"PCSD OK seq=1\nPCSD PASS error=ESP_OK\n")
                        .unwrap();
                }
                std::thread::sleep(Duration::from_millis(100));
            });
            let directory = tempfile::tempdir().unwrap();
            let target = directory.path().join("game.gbc");
            let mut session = Session::start(&mut client, Duration::from_secs(3)).unwrap();
            let result = session.download("/game.gbc", &target, &mut |_| {});
            if corrupt {
                assert!(result.is_err());
                assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
            } else {
                let file = result.unwrap();
                session.finish().unwrap();
                assert_eq!(std::fs::read(file.path()).unwrap(), expected);
            }
            assert!(!target.exists());
            peer.join().unwrap();
        }
    }

    #[test]
    fn paths_preserve_japanese_and_reject_fat_traversal_aliases() {
        for path in ["/", "/CHROMATIC/ボンバーマン.gbc", "/a b/c.sav"] {
            assert!(validate_path(path).is_ok(), "{path}");
        }
        for path in [
            "", "a", "/../a", "/a/./b", "/a//b", "/a/", "/a.", "/a ", "/a\\b", "/x\0y", "/C:foo",
        ] {
            assert!(validate_path(path).is_err(), "{path:?}");
        }
    }
}
