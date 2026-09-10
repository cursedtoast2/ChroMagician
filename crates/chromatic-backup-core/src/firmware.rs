//! Read the stock console's firmware command at either supported UART speed.

use std::io;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serialport::{DataBits, FlowControl, Parity, StopBits};

use crate::{BackupError, discover_ports};

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct FirmwareInfo {
    pub mcu: String,
    pub fpga: String,
    pub chromatic: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct DeviceStatus {
    pub enabled: Option<bool>,
    pub cartridge_present: Option<bool>,
}

fn parse_device_status(line: &[u8]) -> Option<DeviceStatus> {
    let start = crate::find_subslice(line, b"PCSTATUS ")?;
    let text = std::str::from_utf8(&line[start..]).ok()?;
    let mut enabled = None;
    let mut cartridge_present = None;
    for word in text.split_ascii_whitespace().skip(1) {
        match word {
            "enabled=0" => enabled = Some(false),
            "enabled=1" => enabled = Some(true),
            "cartridge=0" => cartridge_present = Some(false),
            "cartridge=1" => cartridge_present = Some(true),
            "cartridge=-1" => {}
            _ => return None,
        }
    }
    enabled.map(|value| DeviceStatus {
        enabled: Some(value),
        cartridge_present,
    })
}

pub(crate) fn device_status(
    port: &mut dyn serialport::SerialPort,
) -> Result<DeviceStatus, BackupError> {
    let current = port.baud_rate()?;
    let other = if current == 115_200 {
        2_000_000
    } else {
        115_200
    };
    for baud in [current, other] {
        port.set_baud_rate(baud)?;
        port.clear(serialport::ClearBuffer::Input)?;
        port.write_all(b"\x15\rpcstatus\r")?;
        let deadline = Instant::now() + Duration::from_millis(750);
        while let Some(line) = crate::read_line_until(port, deadline)? {
            if let Some(status) = parse_device_status(&line) {
                return Ok(status);
            }
            if crate::find_subslice(&line, b"Unrecognized command").is_some() {
                return Ok(DeviceStatus::default());
            }
        }
    }
    port.set_baud_rate(current)?;
    Ok(DeviceStatus::default())
}

fn parse_version(line: &[u8]) -> Option<FirmwareInfo> {
    let start = line.iter().position(|byte| *byte == b'{')?;
    let end = line.iter().rposition(|byte| *byte == b'}')?;
    let version: FirmwareInfo = serde_json::from_slice(line.get(start..=end)?).ok()?;
    if [&version.mcu, &version.fpga, &version.chromatic]
        .iter()
        .any(|value| value.is_empty() || value.len() > 32)
    {
        return None;
    }
    Some(version)
}

/// Read firmware versions through the stock console or PC Backup console.
///
/// # Errors
/// Returns an error if discovery, serial I/O, or the bounded version query fails.
pub fn firmware_info(requested_port: Option<&str>) -> Result<FirmwareInfo, BackupError> {
    read_firmware_info(requested_port, false, None)
}

/// Verify running firmware after flashing, restarting a silent MCU if needed.
/// Never use this probe during discovery or gameplay.
///
/// # Errors
/// Returns an error if discovery, serial I/O, or the bounded version query fails.
pub fn firmware_info_after_flash(
    requested_port: Option<&str>,
    expected: Option<&FirmwareInfo>,
) -> Result<FirmwareInfo, BackupError> {
    read_firmware_info(requested_port, true, expected)
}

fn read_firmware_info(
    requested_port: Option<&str>,
    after_flash: bool,
    expected: Option<&FirmwareInfo>,
) -> Result<FirmwareInfo, BackupError> {
    let name = match requested_port {
        Some(name) => name.to_owned(),
        None => match discover_ports()?.as_slice() {
            [] => return Err(BackupError::DeviceNotFound),
            [name] => name.clone(),
            names => return Err(BackupError::MultipleDevices(names.join(", "))),
        },
    };
    let mut port = serialport::new(name, 115_200)
        .data_bits(DataBits::Eight)
        .flow_control(FlowControl::None)
        .parity(Parity::None)
        .stop_bits(StopBits::One)
        .timeout(Duration::from_millis(100))
        .open()?;
    port.write_data_terminal_ready(false)?;
    port.write_request_to_send(false)?;
    std::thread::sleep(Duration::from_millis(750));
    query_versions(port.as_mut(), after_flash, expected, restart_mcu)
}

fn restart_mcu(port: &mut dyn serialport::SerialPort) -> Result<(), BackupError> {
    reset_control_lines(
        |line| match line {
            ResetLine::Dtr(state) => port.write_data_terminal_ready(state),
            ResetLine::Rts(state) => port.write_request_to_send(state),
        },
        cfg!(windows),
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ResetLine {
    Dtr(bool),
    Rts(bool),
}

fn reset_control_lines(
    mut write_line: impl FnMut(ResetLine) -> serialport::Result<()>,
    resubmit_dtr: bool,
) -> Result<(), BackupError> {
    write_line(ResetLine::Dtr(false))?;
    pulse_reset(|asserted| {
        let rts = write_line(ResetLine::Rts(asserted));
        if resubmit_dtr {
            let dtr = write_line(ResetLine::Dtr(false));
            rts?;
            dtr?;
            Ok(())
        } else {
            rts
        }
    })
}

fn pulse_reset(mut set_rts: impl FnMut(bool) -> serialport::Result<()>) -> Result<(), BackupError> {
    let asserted = set_rts(true);
    if asserted.is_ok() {
        std::thread::sleep(Duration::from_millis(100));
    }
    let released = set_rts(false);
    asserted?;
    released?;
    Ok(())
}

fn query_versions(
    port: &mut dyn serialport::SerialPort,
    after_flash: bool,
    expected: Option<&FirmwareInfo>,
    mut restart: impl FnMut(&mut dyn serialport::SerialPort) -> Result<(), BackupError>,
) -> Result<FirmwareInfo, BackupError> {
    for (attempt, (baud, window_ms, retry_ms)) in [
        (2_000_000, 500, 200),
        (115_200, 500, 200),
        (115_200, 3000, 750),
        (2_000_000, 3000, 750),
    ]
    .into_iter()
    .take(if after_flash { 4 } else { 2 })
    .enumerate()
    {
        port.set_baud_rate(baud)?;
        port.clear(serialport::ClearBuffer::Input)?;
        let mut awaiting_prompt = after_flash && attempt >= 2;
        if awaiting_prompt {
            restart(port)?;
        }
        let window_ms = if awaiting_prompt { 4000 } else { window_ms };
        let deadline = Instant::now() + Duration::from_millis(window_ms);
        let mut next_query = Instant::now();
        let mut line = Vec::new();
        let mut buffer = [0_u8; 512];
        while Instant::now() < deadline {
            if !awaiting_prompt && Instant::now() >= next_query {
                port.write_all(b"\x15\rfwversion\r")?;
                next_query = Instant::now() + Duration::from_millis(retry_ms);
            }
            match port.read(&mut buffer) {
                Ok(count) => {
                    for &byte in &buffer[..count] {
                        if matches!(byte, b'\r' | b'\n') {
                            if let Some(version) = parse_version(&line)
                                && (!after_flash || version.fpga != "0.0")
                                && expected.is_none_or(|wanted| &version == wanted)
                            {
                                return Ok(version);
                            }
                            line.clear();
                        } else if line.len() < 8192 {
                            line.push(byte);
                            if awaiting_prompt && line.ends_with(b"mcu>") {
                                awaiting_prompt = false;
                                next_query = Instant::now();
                            }
                        } else {
                            line.clear();
                        }
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
                    ) => {}
                Err(error) => return Err(error.into()),
            }
        }
    }
    Err(BackupError::Protocol(
        "Chromatic did not report firmware versions. Check its power and USB connection.".into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_reset_reaches_a_driver_that_only_sends_controls_on_dtr() {
        let mut pending_rts = false;
        let mut wire_rts = false;
        let mut asserted_at = None;
        let mut pulses = Vec::new();
        reset_control_lines(
            |line| {
                match line {
                    ResetLine::Rts(state) => pending_rts = state,
                    ResetLine::Dtr(dtr) => {
                        assert!(!dtr, "DTR must stay low for normal firmware boot");
                        if pending_rts != wire_rts {
                            if pending_rts {
                                asserted_at = Some(Instant::now());
                            } else {
                                pulses.push(asserted_at.take().unwrap().elapsed());
                            }
                            wire_rts = pending_rts;
                        }
                    }
                }
                Ok(())
            },
            true,
        )
        .unwrap();
        assert!(!wire_rts, "The MCU must be released from reset");
        assert_eq!(pulses.len(), 1);
        assert!(pulses[0] >= Duration::from_millis(100));
    }

    #[test]
    fn reset_releases_both_controls_when_windows_sync_fails() {
        let mut calls = Vec::new();
        let result = reset_control_lines(
            |line| {
                calls.push(line);
                if calls.len() == 3 {
                    Err(serialport::Error::new(
                        serialport::ErrorKind::Io(io::ErrorKind::Other),
                        "DTR request failed after reaching the device",
                    ))
                } else {
                    Ok(())
                }
            },
            true,
        );
        assert!(result.is_err());
        assert_eq!(
            calls,
            [
                ResetLine::Dtr(false),
                ResetLine::Rts(true),
                ResetLine::Dtr(false),
                ResetLine::Rts(false),
                ResetLine::Dtr(false),
            ]
        );
    }

    #[test]
    fn unix_reset_keeps_the_existing_control_sequence() {
        let mut calls = Vec::new();
        reset_control_lines(
            |line| {
                calls.push(line);
                Ok(())
            },
            false,
        )
        .unwrap();
        assert_eq!(
            calls,
            [
                ResetLine::Dtr(false),
                ResetLine::Rts(true),
                ResetLine::Rts(false),
            ]
        );
    }

    #[test]
    fn reset_pulse_releases_rts_even_when_assertion_fails() {
        for fail in [false, true] {
            let mut states = Vec::new();
            let started = Instant::now();
            let result = pulse_reset(|asserted| {
                states.push(asserted);
                if asserted && fail {
                    Err(serialport::Error::new(
                        serialport::ErrorKind::Io(io::ErrorKind::Other),
                        "write failed",
                    ))
                } else {
                    Ok(())
                }
            });
            assert_eq!(states, [true, false]);
            assert_eq!(result.is_err(), fail);
            if !fail {
                assert!(started.elapsed() >= Duration::from_millis(100));
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn sleeping_firmware_wakes_after_flash_at_either_baud() {
        use serialport::SerialPort as _;
        use std::io::{Read as _, Write as _};
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
            mpsc,
        };
        for baud in [115_200, 2_000_000] {
            let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
            client.set_timeout(Duration::from_millis(25)).unwrap();
            device.set_timeout(Duration::from_millis(25)).unwrap();
            let (reset, resets) = mpsc::channel();
            let finished = Arc::new(AtomicBool::new(false));
            let stop = finished.clone();
            let peer = std::thread::spawn(move || {
                let mut awake = false;
                let mut requests = 0;
                let mut command = Vec::new();
                let mut buffer = [0; 128];
                while !stop.load(Ordering::Relaxed) {
                    if let Ok(speed) = resets.try_recv() {
                        awake = speed == baud;
                        command.clear();
                        if awake {
                            device.write_all(b"Booting\r\nmc").unwrap();
                            std::thread::sleep(Duration::from_millis(10));
                            device.write_all(b"u> ").unwrap();
                        }
                    }
                    match device.read(&mut buffer) {
                        Ok(count) => {
                            for &byte in &buffer[..count] {
                                command.push(byte);
                                if byte == b'\r' {
                                    if awake
                                        && command.ends_with(b"fwversion\r")
                                        && device.baud_rate().unwrap() == baud
                                    {
                                        requests += 1;
                                        let fpga = if requests == 1 { "0.0" } else { "18.37" };
                                        write!(device, "{{\"mcu\":\"v0.13.4\",\"fpga\":\"{fpga}\",\"chromatic\":\"v4.2\"}}\r\n").unwrap();
                                    }
                                    command.clear();
                                }
                            }
                        }
                        Err(e)
                            if matches!(
                                e.kind(),
                                io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
                            ) => {}
                        Err(e) => panic!("{e}"),
                    }
                }
                requests
            });
            let mut restarts = 0;
            let result = query_versions(&mut client, true, None, |port| {
                restarts += 1;
                reset.send(port.baud_rate()?).unwrap();
                Ok(())
            });
            finished.store(true, Ordering::Relaxed);
            assert_eq!(peer.join().unwrap(), 2, "Wait for a nonzero FPGA version");
            assert_eq!(result.unwrap().fpga, "18.37");
            assert_eq!(restarts, if baud == 115_200 { 1 } else { 2 });
        }
    }

    #[cfg(unix)]
    #[test]
    fn post_flash_restarts_a_console_reporting_a_cached_fpga_version() {
        use serialport::SerialPort as _;
        use std::io::{Read as _, Write as _};
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
            mpsc,
        };
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(25)).unwrap();
        device.set_timeout(Duration::from_millis(25)).unwrap();
        let (reset, resets) = mpsc::channel();
        let stopped = Arc::new(AtomicBool::new(false));
        let stop = stopped.clone();
        let peer = std::thread::spawn(move || {
            let mut restarted = false;
            let mut old_replies = 0;
            let mut command = Vec::new();
            let mut buffer = [0; 128];
            while !stop.load(Ordering::Relaxed) {
                if resets.try_recv().is_ok() {
                    restarted = true;
                    command.clear();
                    device.write_all(b"Booting\r\nmcu> ").unwrap();
                }
                match device.read(&mut buffer) {
                    Ok(count) => {
                        for &byte in &buffer[..count] {
                            command.push(byte);
                            if byte == b'\r' {
                                if command.ends_with(b"fwversion\r")
                                    && device.baud_rate().unwrap() == 115_200
                                {
                                    let fpga = if restarted {
                                        "18.8"
                                    } else {
                                        old_replies += 1;
                                        "18.37"
                                    };
                                    write!(device, "{{\"mcu\":\"v0.13.4\",\"fpga\":\"{fpga}\",\"chromatic\":\"v4.2\"}}\r\n").unwrap();
                                }
                                command.clear();
                            }
                        }
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
                        ) => {}
                    Err(e) => panic!("{e}"),
                }
            }
            old_replies
        });
        let expected = FirmwareInfo {
            mcu: "v0.13.4".into(),
            fpga: "18.8".into(),
            chromatic: "v4.2".into(),
        };
        let mut restarts = 0;
        let result = query_versions(&mut client, true, Some(&expected), |_| {
            restarts += 1;
            reset.send(()).unwrap();
            Ok(())
        });
        stopped.store(true, Ordering::Relaxed);
        assert!(
            peer.join().unwrap() > 0,
            "The old FPGA version must actually have been received"
        );
        assert_eq!(result.unwrap(), expected);
        assert_eq!(restarts, 1);
    }

    #[cfg(unix)]
    #[test]
    fn unresponsive_post_flash_console_has_a_bounded_reset_count() {
        use serialport::SerialPort as _;
        let (mut client, _device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(25)).unwrap();
        let mut restarts = 0;
        let started = Instant::now();
        assert!(
            query_versions(&mut client, true, None, |_| {
                restarts += 1;
                Ok(())
            })
            .is_err()
        );
        assert_eq!(restarts, 2);
        assert!(started.elapsed() < Duration::from_secs(12));
    }

    #[cfg(unix)]
    #[test]
    fn passive_query_never_restarts_an_unresponsive_console() {
        use serialport::SerialPort as _;
        let (mut client, _device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(25)).unwrap();
        assert!(
            query_versions(&mut client, false, None, |_| panic!(
                "Passive query reset the MCU"
            ))
            .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn reads_mode_and_physical_presence_without_opening_a_cart_session() {
        use serialport::SerialPort as _;
        use std::io::{Read as _, Write as _};
        let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(50)).unwrap();
        device.set_timeout(Duration::from_secs(2)).unwrap();
        let peer = std::thread::spawn(move || {
            for reply in [
                "PCSTATUS enabled=0 cartridge=-1\n",
                "PCSTATUS enabled=1 cartridge=0\n",
                "PCSTATUS enabled=1 cartridge=1\n",
            ] {
                let mut command = [0; 11];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\x15\rpcstatus\r");
                device.write_all(reply.as_bytes()).unwrap();
            }
            std::thread::sleep(Duration::from_millis(100));
        });
        assert_eq!(
            device_status(&mut client).unwrap(),
            DeviceStatus {
                enabled: Some(false),
                cartridge_present: None
            }
        );
        assert_eq!(
            device_status(&mut client).unwrap(),
            DeviceStatus {
                enabled: Some(true),
                cartridge_present: Some(false)
            }
        );
        assert_eq!(
            device_status(&mut client).unwrap(),
            DeviceStatus {
                enabled: Some(true),
                cartridge_present: Some(true)
            }
        );
        peer.join().unwrap();
        assert_eq!(parse_device_status(b"PCSTATUS enabled=2 cartridge=0"), None);
    }

    #[cfg(unix)]
    #[test]
    fn unrecognized_command_preserves_speed_without_claiming_custom_firmware() {
        use serialport::SerialPort as _;
        use std::io::{Read as _, Write as _};
        for baud in [115_200, 2_000_000] {
            let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
            client.set_baud_rate(baud).unwrap();
            client.set_timeout(Duration::from_millis(50)).unwrap();
            device.set_timeout(Duration::from_secs(2)).unwrap();
            let peer = std::thread::spawn(move || {
                let mut command = [0; 11];
                device.read_exact(&mut command).unwrap();
                assert_eq!(&command, b"\x15\rpcstatus\r");
                device
                    .write_all(b"pcstatus\r\nUnrecognized command\r\n")
                    .unwrap();
                std::thread::sleep(Duration::from_millis(100));
            });
            assert_eq!(device_status(&mut client).unwrap(), DeviceStatus::default());
            assert_eq!(client.baud_rate().unwrap(), baud);
            peer.join().unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn silent_startup_is_bounded_and_never_restarts_the_mcu() {
        use serialport::SerialPort as _;
        let (mut client, _device) = serialport::TTYPort::pair().unwrap();
        client.set_timeout(Duration::from_millis(25)).unwrap();
        let started = Instant::now();
        let result = query_versions(&mut client, false, None, |_| {
            panic!("Discovery must not restart the MCU")
        });
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn accepts_stock_and_custom_versions_among_console_output() {
        for label in ["v4.2", "4.2 CM", "ChroMagic 1.0.0-rc.1 (4.2)"] {
            let line = format!(
                "\x1b[0m> {{\"mcu\":\"v0.13.4\",\"fpga\":\"18.10\",\"chromatic\":\"{label}\" }}"
            );
            assert_eq!(parse_version(line.as_bytes()).unwrap().chromatic, label);
        }
        assert!(parse_version(b"fwversion").is_none());
        assert!(parse_version(b"{\"event\":\"complete\"}").is_none());
        assert!(
            parse_version(b"{\"mcu\":\"\",\"fpga\":\"18.10\",\"chromatic\":\"4.2\"}").is_none()
        );
    }

    #[cfg(unix)]
    #[test]
    fn reads_fragmented_versions_at_either_baud_without_a_long_first_timeout() {
        use serialport::SerialPort as _;
        use std::io::{Read as _, Write as _};
        for (baud, ignored_requests, after_flash) in [
            (115_200, 0, false),
            (2_000_000, 0, false),
            (2_000_000, 1, false),
            (115_200, 2, false),
            (115_200, 0, true),
            (2_000_000, 0, true),
        ] {
            let (mut client, mut device) = serialport::TTYPort::pair().unwrap();
            client.set_timeout(Duration::from_millis(50)).unwrap();
            device.set_timeout(Duration::from_secs(4)).unwrap();
            let (finished, wait) = std::sync::mpsc::channel();
            let peer = std::thread::spawn(move || {
                let mut requests = 0;
                let mut command = Vec::new();
                let mut byte = [0];
                loop {
                    device.read_exact(&mut byte).unwrap();
                    command.push(byte[0]);
                    if command.ends_with(b"fwversion\r") {
                        command.clear();
                        if device.baud_rate().unwrap() != baud {
                            continue;
                        }
                        requests += 1;
                        if requests <= ignored_requests {
                            continue;
                        }
                        device
                            .write_all(
                                b"fwversion\r\n{\"event\":\"noise\"}\n\x1b[0m> {\"mcu\":\"v0.",
                            )
                            .unwrap();
                        std::thread::sleep(Duration::from_millis(10));
                        device
                            .write_all(b"13.4\",\"fpga\":\"18.10\",\"chromatic\":\"4.2 CM\"}\r\n")
                            .unwrap();
                        wait.recv_timeout(Duration::from_secs(3)).unwrap();
                        return requests;
                    }
                }
            });
            let started = Instant::now();
            let version = query_versions(&mut client, after_flash, None, |_| {
                panic!("Responsive console was reset")
            })
            .unwrap();
            let elapsed = started.elapsed();
            assert_eq!(version.chromatic, "4.2 CM");
            assert_eq!(client.baud_rate().unwrap(), baud);
            finished.send(()).unwrap();
            assert_eq!(peer.join().unwrap(), ignored_requests + 1);
            if ignored_requests <= 1 {
                assert!(
                    elapsed < Duration::from_secs(2),
                    "ready console at {baud} took {elapsed:?}"
                );
            }
        }
    }
}
