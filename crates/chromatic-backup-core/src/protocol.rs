use std::collections::BTreeMap;

use crate::BackupError;

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum Record {
    Info(BTreeMap<String, String>),
    Begin(BTreeMap<String, String>),
    Data(BTreeMap<String, String>),
    End(BTreeMap<String, String>),
    Fail(BTreeMap<String, String>),
    Pass,
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum ImportRecord {
    Info(BTreeMap<String, String>),
    Ready(BTreeMap<String, String>),
    Send(BTreeMap<String, String>),
    Progress(BTreeMap<String, String>),
    Fail(BTreeMap<String, String>),
    Pass,
}

pub(crate) fn parse_record(line: &str) -> Result<Record, BackupError> {
    let mut words = line.split_ascii_whitespace();
    if words.next() != Some("PCBACKUP") {
        return Err(BackupError::Protocol(format!(
            "malformed device response: {line:?}"
        )));
    }
    let record = words
        .next()
        .ok_or_else(|| BackupError::Protocol("device response omitted record type".into()))?;
    let mut fields = BTreeMap::new();
    for word in words {
        if let Some((key, value)) = word.split_once('=') {
            fields.insert(key.to_owned(), value.to_owned());
        }
    }
    match record {
        "INFO" => Ok(Record::Info(fields)),
        "BEGIN" => Ok(Record::Begin(fields)),
        "DATA" => Ok(Record::Data(fields)),
        "END" => Ok(Record::End(fields)),
        "FAIL" => Ok(Record::Fail(fields)),
        "PASS" => Ok(Record::Pass),
        _ => Err(BackupError::Protocol(format!(
            "unknown device record {record:?}"
        ))),
    }
}

pub(crate) fn parse_import_record(line: &str) -> Result<ImportRecord, BackupError> {
    let mut words = line.split_ascii_whitespace();
    if words.next() != Some("PCIMPORT") {
        return Err(BackupError::Protocol(format!(
            "malformed device response: {line:?}"
        )));
    }
    let record = words
        .next()
        .ok_or_else(|| BackupError::Protocol("device response omitted record type".into()))?;
    let mut fields = BTreeMap::new();
    for word in words {
        if let Some((key, value)) = word.split_once('=') {
            fields.insert(key.to_owned(), value.to_owned());
        }
    }
    match record {
        "INFO" => Ok(ImportRecord::Info(fields)),
        "READY" => Ok(ImportRecord::Ready(fields)),
        "SEND" => Ok(ImportRecord::Send(fields)),
        "PROGRESS" => Ok(ImportRecord::Progress(fields)),
        "FAIL" => Ok(ImportRecord::Fail(fields)),
        "PASS" => Ok(ImportRecord::Pass),
        _ => Err(BackupError::Protocol(format!(
            "unknown device record {record:?}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_info_fields() {
        let record = parse_record(
            "PCBACKUP INFO protocol=2 transport=usb-bulk title=504f4b454d4f4e20524544 type=13",
        )
        .unwrap();
        let Record::Info(fields) = record else {
            panic!("wrong record");
        };
        assert_eq!(fields["protocol"], "2");
        assert_eq!(fields["transport"], "usb-bulk");
        assert_eq!(fields["type"], "13");
    }

    #[test]
    fn rejects_unknown_record() {
        assert!(parse_record("PCBACKUP MAYBE value=1").is_err());
    }

    #[test]
    fn parses_import_send_fields() {
        let record =
            parse_import_record("PCIMPORT SEND phase=write kind=sav seq=2 offset=2048 size=1024")
                .unwrap();
        let ImportRecord::Send(fields) = record else {
            panic!("wrong record");
        };
        assert_eq!(fields["phase"], "write");
        assert_eq!(fields["offset"], "2048");
    }
}
