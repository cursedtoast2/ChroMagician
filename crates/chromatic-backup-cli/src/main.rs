use std::io::{self, BufRead as _, Write as _};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
    mpsc,
};
use std::time::Duration;

use chromatic_backup_core::{
    ArtifactKind, BackupError, BackupEvent, BackupRequest, FirmwareInfo, RomWriteEvent,
    RomWriteRequest, SaveImportEvent, SaveImportRequest, SdOperation, backup, discover_ports,
    firmware_info, firmware_info_after_flash, import_save, inspect_cartridge, list_sd_on_port,
    probe_flash, sd_files, watch_device, write_rom,
};
use clap::Parser;
use serde_json::json;

#[derive(Debug, Parser)]
#[allow(clippy::struct_excessive_bools)]
#[command(
    version,
    about = "Read and write GB/GBC cartridges through a ModRetro Chromatic",
    group(clap::ArgGroup::new("write").args(["write_rom", "import_sav"])),
    group(clap::ArgGroup::new("sd_destination").args(["sd_rename", "sd_move", "sd_import"])),
    group(clap::ArgGroup::new("sd").multiple(false).conflicts_with_all(["devices", "watch", "inspect", "rom", "sav", "write_rom", "import_sav", "probe_flash"]))
)]
struct Arguments {
    /// Read MCU/FPGA versions in stock or custom firmware, without PC Backup mode.
    #[arg(long, conflicts_with_all = ["sd", "devices", "watch", "inspect", "rom", "sav", "write_rom", "import_sav", "probe_flash", "yes", "force"])]
    firmware_info: bool,
    /// Allow a bounded MCU restart when verifying a completed firmware install.
    #[arg(long, requires = "firmware_info", conflicts_with_all = ["sd", "devices", "watch", "inspect", "rom", "sav", "write_rom", "import_sav", "probe_flash", "yes", "force"])]
    after_flash: bool,
    /// Require the installed versions before completing post-flash verification.
    #[arg(long, requires = "after_flash", value_parser = parse_expected_firmware)]
    expected_firmware: Option<FirmwareInfo>,
    /// Inspect/manage SD files without exposing a USB mass-storage device.
    #[arg(long, group = "sd")]
    sd_status: bool,
    #[arg(long, value_name = "SD_PATH", group = "sd")]
    sd_list: Option<String>,
    #[arg(long, value_name = "SD_PATH", group = "sd", requires = "file")]
    sd_get: Option<String>,
    #[arg(long, value_name = "SD_PATH", group = "sd", requires = "file")]
    sd_put: Option<String>,
    #[arg(long, num_args = 1.., value_name = "LOCAL_PATH", group = "sd", requires = "destination")]
    sd_import: Vec<PathBuf>,
    #[arg(long, group = "sd")]
    sd_initialize: bool,
    #[arg(long, value_name = "SD_PATH", group = "sd", requires = "destination")]
    sd_rename: Option<String>,
    /// Move selected files or folders into one SD directory.
    #[arg(long, num_args = 1.., value_name = "SD_PATH", group = "sd", requires = "destination")]
    sd_move: Vec<String>,
    /// Delete selected files or folders, including folder contents.
    #[arg(long, num_args = 1.., value_name = "SD_PATH", group = "sd")]
    sd_delete_many: Vec<String>,
    #[arg(long, value_name = "SD_PATH", group = "sd")]
    sd_mkdir: Option<String>,
    #[arg(long, value_name = "SD_PATH", group = "sd")]
    sd_delete: Option<String>,
    /// Delete a folder and all its contents from the SD card.
    #[arg(long, value_name = "SD_PATH", group = "sd")]
    sd_delete_tree: Option<String>,
    /// Back up ROM, save and matching RTC to SD, replacing the same filenames.
    #[arg(long, value_name = "SD_PATH", group = "sd")]
    sd_backup_rom: Option<String>,
    /// Back up save RAM and its matching RTC directly to SD.
    #[arg(long, value_name = "SD_PATH", group = "sd")]
    sd_backup_sav: Option<String>,
    #[arg(long, value_name = "LOCAL_FILE", requires = "sd")]
    file: Option<PathBuf>,
    #[arg(long, value_name = "SD_PATH", requires = "sd_destination")]
    destination: Option<String>,

    /// Serial device; the Chromatic is auto-detected when omitted.
    #[arg(long)]
    port: Option<String>,

    /// List connected Chromatic USB ports without opening them.
    #[arg(long, conflicts_with_all = ["rom", "sav", "write_rom", "import_sav", "probe_flash", "inspect", "yes", "force"])]
    devices: bool,

    /// Read the cartridge header without dumping files or programming flash.
    #[arg(long, conflicts_with_all = ["rom", "sav", "write_rom", "import_sav", "probe_flash", "yes", "force"])]
    inspect: bool,

    /// Automatically report inserted games until standard input closes.
    #[arg(long, conflicts_with_all = ["devices", "inspect", "rom", "sav", "write_rom", "import_sav", "probe_flash", "yes", "force"])]
    watch: bool,

    /// Write the cartridge ROM to this file.
    #[arg(long, value_name = "FILE")]
    rom: Option<PathBuf>,

    /// Write save RAM and a same-stem .rtc file when the cartridge has an RTC.
    #[arg(long, value_name = "FILE")]
    sav: Option<PathBuf>,

    /// Flash a ROM to a supported `ModRetro` cartridge (up to 4 MiB).
    #[arg(long, value_name = "FILE", requires = "yes", conflicts_with_all = ["rom", "sav", "import_sav", "force", "probe_flash"])]
    write_rom: Option<PathBuf>,

    /// Identify a supported `ModRetro` flash chip without erasing/programming it.
    #[arg(long, conflicts_with_all = ["rom", "sav", "import_sav", "force", "yes"])]
    probe_flash: bool,

    /// Write save RAM; automatically include a same-stem .rtc file beside it.
    #[arg(long = "write-sav", visible_alias = "import-sav", value_name = "FILE", requires = "yes", conflicts_with_all = ["rom", "sav", "force"])]
    import_sav: Option<PathBuf>,

    /// Restore only save RAM, explicitly omitting any matching RTC sidecar.
    #[arg(long, requires = "import_sav")]
    save_only: bool,

    /// Confirm overwriting the inserted cartridge ROM or save.
    #[arg(long, requires = "write")]
    yes: bool,

    /// Replace existing output files.
    #[arg(long)]
    force: bool,

    /// Emit one machine-readable JSON object per line.
    #[arg(long)]
    json: bool,

    /// Overall operation timeout in seconds.
    #[arg(long, default_value_t = 300)]
    timeout: u64,

    /// Startup settling time after opening USB, in milliseconds.
    #[arg(long, default_value_t = 3000)]
    boot_wait_ms: u64,
}

fn sd_operation(arguments: &Arguments) -> Option<SdOperation> {
    if arguments.sd_initialize {
        Some(SdOperation::InitializeBackups)
    } else if !arguments.sd_import.is_empty() {
        Some(SdOperation::Import {
            sources: arguments.sd_import.clone(),
            destination: arguments.destination.clone().expect("clap destination"),
        })
    } else if !arguments.sd_move.is_empty() {
        Some(SdOperation::MoveMany {
            paths: arguments.sd_move.clone(),
            destination: arguments.destination.clone().expect("clap destination"),
        })
    } else if !arguments.sd_delete_many.is_empty() {
        Some(SdOperation::DeleteMany(arguments.sd_delete_many.clone()))
    } else if let Some(path) = &arguments.sd_backup_rom {
        Some(SdOperation::Backup {
            remote: path.clone(),
            save: false,
        })
    } else if let Some(path) = &arguments.sd_backup_sav {
        Some(SdOperation::Backup {
            remote: path.clone(),
            save: true,
        })
    } else if arguments.sd_status {
        Some(SdOperation::Status)
    } else if let Some(path) = &arguments.sd_list {
        Some(SdOperation::List(path.clone()))
    } else if let Some(path) = &arguments.sd_get {
        Some(SdOperation::Download {
            remote: path.clone(),
            local: arguments.file.clone().expect("clap file"),
            overwrite: arguments.force,
        })
    } else if let Some(path) = &arguments.sd_put {
        Some(SdOperation::Upload {
            remote: path.clone(),
            local: arguments.file.clone().expect("clap file"),
        })
    } else if let Some(path) = &arguments.sd_rename {
        Some(SdOperation::Rename {
            from: path.clone(),
            to: arguments.destination.clone().expect("clap destination"),
        })
    } else if let Some(path) = &arguments.sd_mkdir {
        Some(SdOperation::Mkdir(path.clone()))
    } else if let Some(path) = &arguments.sd_delete_tree {
        Some(SdOperation::DeleteTree(path.clone()))
    } else {
        arguments
            .sd_delete
            .as_ref()
            .map(|path| SdOperation::Delete(path.clone()))
    }
}

fn parse_expected_firmware(value: &str) -> Result<FirmwareInfo, String> {
    serde_json::from_str(value).map_err(|error| error.to_string())
}

fn run_firmware_info(arguments: &Arguments) -> ExitCode {
    let result = if arguments.after_flash {
        firmware_info_after_flash(
            arguments.port.as_deref(),
            arguments.expected_firmware.as_ref(),
        )
    } else {
        firmware_info(arguments.port.as_deref())
    };
    match result {
        Ok(version) => {
            println!(
                "{}",
                json!({"schema_version":1, "event":"firmware_info", "version":version})
            );
            println!(
                "{}",
                json!({"event":"complete", "operation":"firmware_info"})
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            render_error(&error, arguments.json);
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    let arguments = Arguments::parse();
    if arguments.firmware_info {
        return run_firmware_info(&arguments);
    }
    let sd = sd_operation(&arguments);
    if let Some(operation) = sd {
        let request = RomWriteRequest {
            port: arguments.port,
            timeout: Duration::from_secs(arguments.timeout),
            boot_wait: Duration::from_millis(arguments.boot_wait_ms),
            ..RomWriteRequest::default()
        };
        return match sd_files(&request, &operation, |event| {
            println!("{event}");
            let _ = io::stdout().flush();
        }) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                render_error(&error, arguments.json);
                ExitCode::FAILURE
            }
        };
    }
    if arguments.watch {
        return run_watch(arguments);
    }
    if arguments.devices {
        return match discover_ports() {
            Ok(ports) => {
                if arguments.json {
                    println!(
                        "{}",
                        json!({"event":"devices", "schema_version":1, "ports":ports})
                    );
                } else {
                    for port in ports {
                        println!("{port}");
                    }
                }
                ExitCode::SUCCESS
            }
            Err(error) => {
                render_error(&error, arguments.json);
                ExitCode::FAILURE
            }
        };
    }
    if arguments.inspect {
        let request = RomWriteRequest {
            port: arguments.port,
            timeout: Duration::from_secs(arguments.timeout),
            boot_wait: Duration::from_millis(arguments.boot_wait_ms),
            ..RomWriteRequest::default()
        };
        return match inspect_cartridge(&request, |event| {
            render_rom_write_event(&event, arguments.json);
        }) {
            Ok(cartridge) => {
                if arguments.json {
                    println!(
                        "{}",
                        json!({"event":"cartridge_inspected", "cartridge":cartridge})
                    );
                    println!("{}", json!({"event":"complete", "operation":"inspect"}));
                } else {
                    println!(
                        "Cartridge: {} ({} ROM bytes, {} save bytes)",
                        cartridge.title, cartridge.rom_size, cartridge.save_size
                    );
                }
                ExitCode::SUCCESS
            }
            Err(error) => {
                render_error(&error, arguments.json);
                ExitCode::FAILURE
            }
        };
    }
    run_transfer(arguments)
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct DirectoryRequest {
    id: u64,
    path: String,
}

fn directory_requests(stopped: Arc<AtomicBool>) -> mpsc::Receiver<DirectoryRequest> {
    let (sender, requests) = mpsc::sync_channel::<DirectoryRequest>(1);
    std::thread::spawn(move || {
        for line in io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            let Ok(request) = serde_json::from_str(&line) else {
                break;
            };
            if sender.send(request).is_err() {
                break;
            }
        }
        stopped.store(true, Ordering::Relaxed);
    });
    requests
}

fn run_watch(arguments: Arguments) -> ExitCode {
    let stopped = Arc::new(AtomicBool::new(false));
    let requests = directory_requests(Arc::clone(&stopped));
    let request = RomWriteRequest {
        port: arguments.port,
        boot_wait: Duration::from_millis(arguments.boot_wait_ms),
        ..RomWriteRequest::default()
    };
    if arguments.json {
        println!(
            "{}",
            json!({"event":"session_started", "schema_version":1, "sd_listing":true})
        );
        let _ = io::stdout().flush();
    }
    let result = watch_device(
        &request,
        || stopped.load(Ordering::Relaxed),
        |header| {
            if arguments.json {
                println!(
                    "{}",
                    match header {
                        Some(cartridge) =>
                            json!({"event":"cartridge_inspected", "cartridge":cartridge}),
                        None => json!({"event":"cartridge_unavailable"}),
                    }
                );
            } else if let Some(cartridge) = header {
                println!(
                    "Cartridge: {} (ROM writable: {})",
                    cartridge.header.title, cartridge.rom_writable
                );
            } else {
                println!("Waiting for a game cartridge");
            }
            let _ = io::stdout().flush();
        },
        |status| {
            if arguments.json {
                println!(
                    "{}",
                    json!({"event":"sd_status", "present":status.present, "error":status.error})
                );
            } else {
                println!("SD card present: {}", status.present);
            }
            let _ = io::stdout().flush();
        },
        |status| {
            if arguments.json {
                println!(
                    "{}",
                    json!({"event":"device_status", "enabled":status.enabled,
                                     "cartridge_present":status.cartridge_present})
                );
            }
            let _ = io::stdout().flush();
        },
        |port| {
            if let Ok(request) = requests.try_recv() {
                let result = list_sd_on_port(port, &request.path);
                let response = match &result {
                    Ok(entries) => json!({"event":"sd_list", "id":request.id,
                        "path":request.path, "entries":entries}),
                    Err(error) => json!({"event":"sd_list_error", "id":request.id,
                        "code":error.code(), "message":error.to_string()}),
                };
                println!("{response}");
                let _ = io::stdout().flush();
                if let Err(error) = result
                    && !matches!(error, BackupError::Device(_))
                {
                    return Err(error);
                }
            }
            Ok(())
        },
    );
    match result {
        Ok(()) => {
            if arguments.json {
                println!("{}", json!({"event":"complete", "operation":"watch"}));
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            render_error(&error, arguments.json);
            ExitCode::FAILURE
        }
    }
}

fn run_transfer(arguments: Arguments) -> ExitCode {
    if arguments.write_rom.is_some() || arguments.probe_flash {
        let request = RomWriteRequest {
            port: arguments.port,
            rom_path: arguments.write_rom.unwrap_or_default(),
            timeout: Duration::from_secs(arguments.timeout),
            boot_wait: Duration::from_millis(arguments.boot_wait_ms),
            ..RomWriteRequest::default()
        };
        let render = |event| render_rom_write_event(&event, arguments.json);
        let result = if arguments.probe_flash {
            probe_flash(&request, render)
        } else {
            write_rom(&request, render)
        };
        return match result {
            Ok(_) => ExitCode::SUCCESS,
            Err(error) => {
                render_error(&error, arguments.json);
                ExitCode::FAILURE
            }
        };
    }
    if let Some(save_path) = arguments.import_sav {
        let request = SaveImportRequest {
            port: arguments.port,
            save_path,
            timeout: Duration::from_secs(arguments.timeout),
            boot_wait: Duration::from_millis(arguments.boot_wait_ms),
            save_only: arguments.save_only,
        };
        let json_output = arguments.json;
        return match import_save(&request, |event| render_import_event(&event, json_output)) {
            Ok(_) => ExitCode::SUCCESS,
            Err(error) => {
                render_error(&error, json_output);
                ExitCode::FAILURE
            }
        };
    }
    let request = BackupRequest {
        port: arguments.port,
        rom_path: arguments.rom,
        save_path: arguments.sav,
        force: arguments.force,
        timeout: Duration::from_secs(arguments.timeout),
        boot_wait: Duration::from_millis(arguments.boot_wait_ms),
    };

    let json_output = arguments.json;
    let result = backup(&request, |event| render_event(&event, json_output));
    match result {
        Ok(_) => ExitCode::SUCCESS,
        Err(error) => {
            render_error(&error, json_output);
            ExitCode::FAILURE
        }
    }
}

fn render_import_event(event: &SaveImportEvent, json_output: bool) {
    if json_output {
        println!(
            "{}",
            serde_json::to_string(event).expect("event is serializable")
        );
        let _ = io::stdout().flush();
        return;
    }
    match event {
        SaveImportEvent::SessionStarted { .. } => {}
        SaveImportEvent::DeviceConnected { port } => println!("Connected: {port}"),
        SaveImportEvent::CartridgeDetected { cartridge } => println!(
            "Cartridge: {} (type 0x{:02x})",
            if cartridge.title.is_empty() {
                "<untitled>"
            } else {
                &cartridge.title
            },
            cartridge.cartridge_type
        ),
        SaveImportEvent::ValidationStarted { rtc_included, .. } => println!(
            "Validating save{} before writing",
            if *rtc_included { " and RTC" } else { "" }
        ),
        SaveImportEvent::WriteStarted { rtc_included, .. } => println!(
            "Writing and verifying save{}",
            if *rtc_included { " and RTC" } else { "" }
        ),
        SaveImportEvent::Progress {
            written,
            total,
            percent,
        } => {
            print!("\rSave import: {written}/{total} bytes ({percent}%)");
            let _ = io::stdout().flush();
        }
        SaveImportEvent::Complete { elapsed_ms } => println!(
            "\nSave import complete in {}.{:03}s",
            elapsed_ms / 1000,
            elapsed_ms % 1000
        ),
    }
}

fn render_event(event: &BackupEvent, json_output: bool) {
    if json_output {
        println!(
            "{}",
            serde_json::to_string(event).expect("event is serializable")
        );
        let _ = io::stdout().flush();
        return;
    }
    match event {
        BackupEvent::SessionStarted { .. } => {}
        BackupEvent::DeviceConnected { port } => println!("Connected: {port}"),
        BackupEvent::CartridgeDetected { cartridge } => println!(
            "Cartridge: {} (type 0x{:02x})",
            if cartridge.title.is_empty() {
                "<untitled>"
            } else {
                &cartridge.title
            },
            cartridge.cartridge_type
        ),
        BackupEvent::ArtifactStarted { kind, size, .. } => {
            println!("Receiving {}: {size} bytes", label(*kind));
        }
        BackupEvent::Progress {
            kind,
            received,
            total,
            percent,
        } => {
            print!("\r{}: {received}/{total} bytes ({percent}%)", label(*kind));
            let _ = io::stdout().flush();
        }
        BackupEvent::ArtifactVerified { .. } => println!(),
        BackupEvent::ArtifactSaved { kind, path } => {
            println!("Saved {}: {}", label(*kind), path.display());
        }
        BackupEvent::Complete { elapsed_ms } => {
            println!(
                "Backup complete in {}.{:03}s",
                elapsed_ms / 1000,
                elapsed_ms % 1000
            );
        }
    }
}

fn render_error(error: &BackupError, json_output: bool) {
    if json_output {
        println!(
            "{}",
            json!({
                "event": "error",
                "schema_version": chromatic_backup_core::EVENT_SCHEMA_VERSION,
                "code": error.code(),
                "message": error.to_string(),
            })
        );
    } else {
        eprintln!("error: {error}");
    }
}

const fn label(kind: ArtifactKind) -> &'static str {
    match kind {
        ArtifactKind::Rom => "ROM",
        ArtifactKind::Save => "save",
        ArtifactKind::Rtc => "RTC",
    }
}

fn render_rom_write_event(event: &RomWriteEvent, json_output: bool) {
    if json_output {
        println!(
            "{}",
            serde_json::to_string(event).expect("event is serializable")
        );
        let _ = io::stdout().flush();
        return;
    }
    match event {
        RomWriteEvent::SessionStarted { .. } => {}
        RomWriteEvent::DeviceConnected { port } => println!("Connected: {port}"),
        RomWriteEvent::FlashDetected {
            profile,
            chip_id,
            capacity,
        } => println!("Cartridge: {profile}, flash ID {chip_id}, {capacity} bytes"),
        RomWriteEvent::RomValidated { path, size, .. } => {
            println!("Validated ROM: {} ({size} bytes)", path.display());
        }
        RomWriteEvent::EraseStarted { capacity } => {
            println!("Erasing {capacity} bytes of cartridge ROM");
        }
        RomWriteEvent::Progress {
            phase,
            completed,
            total,
        } => {
            print!("\r{phase}: {completed}/{total} bytes");
            let _ = io::stdout().flush();
        }
        RomWriteEvent::Complete {
            operation,
            elapsed_ms,
        } => println!(
            "\n{operation} complete in {}.{:03}s",
            elapsed_ms / 1000,
            elapsed_ms % 1000
        ),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn reset_permission_is_explicit_and_only_valid_for_firmware_verification() {
        use super::*;
        let args = Arguments::try_parse_from(["cli", "--firmware-info"]).unwrap();
        assert!(!args.after_flash);
        let args = Arguments::try_parse_from(["cli", "--firmware-info", "--after-flash"]).unwrap();
        assert!(args.after_flash);
        let expected = r#"{"mcu":"v0.13.4","fpga":"18.8","chromatic":"v4.2"}"#;
        let args = Arguments::try_parse_from([
            "cli",
            "--firmware-info",
            "--after-flash",
            "--expected-firmware",
            expected,
        ])
        .unwrap();
        assert_eq!(args.expected_firmware.unwrap().fpga, "18.8");
        for args in [
            vec!["cli", "--after-flash"],
            vec!["cli", "--watch", "--after-flash"],
            vec!["cli", "--rom", "backup.gb", "--after-flash"],
            vec!["cli", "--devices", "--firmware-info", "--after-flash"],
            vec!["cli", "--firmware-info", "--expected-firmware", expected],
            vec![
                "cli",
                "--firmware-info",
                "--after-flash",
                "--expected-firmware",
                "{}",
            ],
        ] {
            assert!(Arguments::try_parse_from(args).is_err());
        }
    }

    #[test]
    fn bulk_sd_arguments_require_one_operation_and_a_move_destination() {
        use super::*;
        let args = Arguments::try_parse_from([
            "cli",
            "--sd-move",
            "/a.gb",
            "/a.sav",
            "--destination",
            "/Games",
        ])
        .unwrap();
        assert!(
            matches!(sd_operation(&args), Some(SdOperation::MoveMany { paths, destination }) if paths.len() == 2 && destination == "/Games")
        );
        let args =
            Arguments::try_parse_from(["cli", "--sd-delete-many", "/a.gb", "/Folder"]).unwrap();
        assert!(
            matches!(sd_operation(&args), Some(SdOperation::DeleteMany(paths)) if paths.len() == 2)
        );
        for args in [
            vec!["cli", "--sd-move", "/a"],
            vec!["cli", "--sd-delete-many"],
            vec!["cli", "--sd-delete-many", "/a", "--sd-mkdir", "/b"],
        ] {
            assert!(Arguments::try_parse_from(args).is_err());
        }
    }

    use super::*;

    #[test]
    fn writes_are_separate_and_require_confirmation() {
        assert!(
            Arguments::try_parse_from(["cli", "--devices", "--write-rom", "game.gb", "--yes"])
                .is_err()
        );
        assert!(Arguments::try_parse_from(["cli", "--inspect", "--sav", "game.sav"]).is_err());
        assert!(Arguments::try_parse_from(["cli", "--inspect", "--json"]).is_ok());
        assert!(Arguments::try_parse_from(["cli", "--write-rom", "game.gbc"]).is_err());
        assert!(Arguments::try_parse_from(["cli", "--write-sav", "game.sav"]).is_err());
        for option in ["--write-sav", "--import-sav"] {
            assert!(Arguments::try_parse_from(["cli", option, "game.sav", "--yes"]).is_ok());
        }
        assert!(Arguments::try_parse_from(["cli", "--save-only"]).is_err());
        assert!(
            Arguments::try_parse_from(["cli", "--write-sav", "game.sav", "--save-only", "--yes"])
                .is_ok()
        );
        assert!(Arguments::try_parse_from(["cli", "--write-rom", "game.gbc", "--yes"]).is_ok());
        assert!(
            Arguments::try_parse_from([
                "cli",
                "--write-rom",
                "game.gbc",
                "--write-sav",
                "game.sav",
                "--yes"
            ])
            .is_err()
        );
        assert!(
            Arguments::try_parse_from([
                "cli",
                "--write-rom",
                "game.gbc",
                "--rom",
                "dump.gbc",
                "--yes"
            ])
            .is_err()
        );
        assert!(Arguments::try_parse_from(["cli", "--probe-flash"]).is_ok());
        assert!(Arguments::try_parse_from(["cli", "--probe-flash", "--yes"]).is_err());
    }
}
