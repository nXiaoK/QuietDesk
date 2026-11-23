//! Signed update manifest verification, safe archive extraction, PE header validation,
//! and idle auto-update scheduling policy for QuietDesk on Windows.

use crc32fast::Hasher as Crc32Hasher;
use flate2::read::DeflateDecoder;
use openssl::pkey::{Id, PKey};
use openssl::sha::Sha256;
use openssl::sign::Verifier;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::io::Read;
use std::time::Duration;

pub const PRODUCTION_APP_ID: &str = "QuietDesk.Windows";
pub const WINDOWS_SIGNING_PREFIX: &[u8] = b"QuietDesk-windows-update-v1\n";
pub const MAX_ENVELOPE_BYTES: usize = 64 * 1024;
pub const MAX_ARCHIVE_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_EXTRACTED_BYTES: u64 = 128 * 1024 * 1024;
pub const MAX_NOTES_SCALARS: usize = 4_000;

pub const STARTUP_CHECK_DELAY: Duration = Duration::from_secs(120);
pub const DAILY_CHECK_INTERVAL_SECS: u64 = 24 * 60 * 60;
pub const FAILURE_RETRY_INTERVAL_SECS: u64 = 60 * 60;
pub const POST_SESSION_COOLDOWN: Duration = Duration::from_secs(10);

pub const IMAGE_FILE_MACHINE_I386: u16 = 0x014C;
pub const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
pub const IMAGE_FILE_MACHINE_ARM64: u16 = 0xAA64;
pub const IMAGE_SUBSYSTEM_WINDOWS_GUI: u16 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TargetArch {
    X64,
    Arm64,
}

impl TargetArch {
    pub const fn current() -> Option<Self> {
        #[cfg(target_arch = "x86_64")]
        {
            Some(Self::X64)
        }
        #[cfg(target_arch = "aarch64")]
        {
            Some(Self::Arm64)
        }
        #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
        {
            None
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::X64 => "x64",
            Self::Arm64 => "arm64",
        }
    }

    pub const fn pe_machine(self) -> u16 {
        match self {
            Self::X64 => IMAGE_FILE_MACHINE_AMD64,
            Self::Arm64 => IMAGE_FILE_MACHINE_ARM64,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateError {
    EnvelopeTooLarge,
    MalformedEnvelope,
    UnsupportedFormat,
    UnknownKey,
    InvalidSignature,
    InvalidPayload,
    InvalidField(&'static str),
    UnsafeUrl,
    InvalidArchive(String),
    InvalidExecutable(String),
}

impl fmt::Display for UpdateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EnvelopeTooLarge => write!(f, "更新清单超过大小限制"),
            Self::MalformedEnvelope => write!(f, "更新清单格式无效"),
            Self::UnsupportedFormat => write!(f, "不支持此更新清单格式"),
            Self::UnknownKey => write!(f, "更新清单使用了未知的签名密钥"),
            Self::InvalidSignature => write!(f, "更新清单签名校验失败"),
            Self::InvalidPayload => write!(f, "更新清单内容无效"),
            Self::InvalidField(name) => write!(f, "更新清单字段无效：{name}"),
            Self::UnsafeUrl => write!(f, "更新清单包含不允许的下载地址"),
            Self::InvalidArchive(reason) => write!(f, "{reason}"),
            Self::InvalidExecutable(reason) => write!(f, "{reason}"),
        }
    }
}

impl std::error::Error for UpdateError {}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdatePublicKey {
    pub id: String,
    pub key: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SignedUpdateEnvelope {
    pub format: u32,
    #[serde(rename = "keyID")]
    pub key_id: String,
    pub payload: String,
    pub signature: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateArchive {
    pub url: String,
    pub size: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowsArchPackages {
    pub portable: UpdateArchive,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installer: Option<UpdateArchive>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowsUpdateManifest {
    pub schema: u32,
    pub app_id: String,
    pub version: String,
    pub build: u64,
    pub published_at: String,
    pub revision: String,
    #[serde(rename = "releaseNotesURL")]
    pub release_notes_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    pub packages: BTreeMap<String, WindowsArchPackages>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdateAvailability {
    UpToDate,
    Available,
    InconsistentBuild,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VerificationResult {
    Supported(WindowsUpdateManifest),
    RequiresManualUpdate { schema: u32, release_notes_url: String },
}

/// Compare decimal version components without integer overflow, matching Swift's `UpdateVersion`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UpdateVersion {
    raw: String,
    components: [String; 3],
}

impl UpdateVersion {
    pub fn parse(value: &str) -> Result<Self, UpdateError> {
        let parts: Vec<&str> = value.split('.').collect();
        if parts.len() != 3 || !parts.iter().all(|part| Self::valid_component(part)) {
            return Err(UpdateError::InvalidField("version"));
        }
        Ok(Self { raw: value.to_string(), components: [parts[0].to_string(), parts[1].to_string(), parts[2].to_string()] })
    }

    pub fn as_str(&self) -> &str {
        &self.raw
    }

    fn valid_component(value: &str) -> bool {
        !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) && (value.len() == 1 || !value.starts_with('0'))
    }
}

impl Ord for UpdateVersion {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        for (lhs, rhs) in self.components.iter().zip(other.components.iter()) {
            if lhs != rhs {
                return lhs.len().cmp(&rhs.len()).then_with(|| lhs.cmp(rhs));
            }
        }
        std::cmp::Ordering::Equal
    }
}

impl PartialOrd for UpdateVersion {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl WindowsUpdateManifest {
    pub fn validate(&self, expected_app_id: &str, allow_loopback_for_testing: bool, repository: &str) -> Result<(), UpdateError> {
        if self.schema != 1 {
            return Err(UpdateError::InvalidField("schema"));
        }
        if expected_app_id.is_empty() || self.app_id != expected_app_id {
            return Err(UpdateError::InvalidField("appId"));
        }
        UpdateVersion::parse(&self.version)?;
        if self.build == 0 {
            return Err(UpdateError::InvalidField("build"));
        }
        if !valid_iso8601_timestamp(&self.published_at) {
            return Err(UpdateError::InvalidField("publishedAt"));
        }
        if !self.revision.is_empty() && !(self.revision.len() == 40 && self.revision.bytes().all(|b| b.is_ascii_hexdigit())) {
            return Err(UpdateError::InvalidField("revision"));
        }
        if self.notes.as_ref().is_some_and(|text| text.chars().count() > MAX_NOTES_SCALARS) {
            return Err(UpdateError::InvalidField("notes"));
        }
        validate_release_notes_url(&self.release_notes_url)?;
        if self.packages.is_empty() {
            return Err(UpdateError::InvalidField("packages"));
        }
        for (arch, pkg) in &self.packages {
            if arch.is_empty() || arch.len() > 32 || !arch.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-') {
                return Err(UpdateError::InvalidField("packages"));
            }
            validate_archive(&pkg.portable, &self.app_id, allow_loopback_for_testing, repository)?;
            if let Some(installer) = &pkg.installer {
                validate_archive(installer, &self.app_id, allow_loopback_for_testing, repository)?;
            }
        }
        Ok(())
    }

    pub fn assess(&self, current_version: &str, current_build: u64, arch: TargetArch) -> Result<UpdateAvailability, UpdateError> {
        if current_build == 0 {
            return Err(UpdateError::InvalidField("currentBuild"));
        }
        if UpdateVersion::parse(&self.version)? <= UpdateVersion::parse(current_version)? {
            return Ok(UpdateAvailability::UpToDate);
        }
        if self.build <= current_build {
            return Ok(UpdateAvailability::InconsistentBuild);
        }
        if !self.packages.contains_key(arch.as_str()) {
            return Ok(UpdateAvailability::UpToDate);
        }
        Ok(UpdateAvailability::Available)
    }

    pub fn package_for(&self, arch: TargetArch) -> Option<&WindowsArchPackages> {
        self.packages.get(arch.as_str())
    }
}

fn validate_archive(archive: &UpdateArchive, app_id: &str, allow_loopback: bool, repository: &str) -> Result<(), UpdateError> {
    validate_package_url(&archive.url, app_id, allow_loopback, repository)?;
    if archive.size == 0 || archive.size > MAX_ARCHIVE_BYTES {
        return Err(UpdateError::InvalidField("archive.size"));
    }
    if archive.sha256.len() != 64 || !archive.sha256.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(UpdateError::InvalidField("archive.sha256"));
    }
    Ok(())
}

pub fn verify_manifest(
    data: &[u8],
    public_keys: &[UpdatePublicKey],
    expected_app_id: &str,
    allow_loopback_for_testing: bool,
    repository: &str,
) -> Result<VerificationResult, UpdateError> {
    if data.len() > MAX_ENVELOPE_BYTES {
        return Err(UpdateError::EnvelopeTooLarge);
    }
    let mut seen_ids = HashSet::new();
    for item in public_keys {
        if item.id.is_empty()
            || item.id.len() > 64
            || !item.id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
            || !seen_ids.insert(item.id.as_str())
        {
            return Err(UpdateError::UnknownKey);
        }
    }
    let envelope: SignedUpdateEnvelope = serde_json::from_slice(data).map_err(|_| UpdateError::MalformedEnvelope)?;
    if envelope.format != 1 {
        return Err(UpdateError::UnsupportedFormat);
    }
    let matching: Vec<&UpdatePublicKey> = public_keys.iter().filter(|k| k.id == envelope.key_id).collect();
    let Some(configured_key) = (matching.len() == 1).then(|| matching[0]) else {
        return Err(UpdateError::UnknownKey);
    };
    let key_bytes = decode_base64_strict(&configured_key.key).ok_or(UpdateError::InvalidSignature)?;
    let payload = decode_base64_strict(&envelope.payload).ok_or(UpdateError::InvalidSignature)?;
    let signature = decode_base64_strict(&envelope.signature).ok_or(UpdateError::InvalidSignature)?;
    if key_bytes.len() != 32 || signature.len() != 64 {
        return Err(UpdateError::InvalidSignature);
    }
    let public_key = PKey::public_key_from_raw_bytes(&key_bytes, Id::ED25519).map_err(|_| UpdateError::InvalidSignature)?;
    let mut signed_message = Vec::with_capacity(WINDOWS_SIGNING_PREFIX.len() + payload.len());
    signed_message.extend_from_slice(WINDOWS_SIGNING_PREFIX);
    signed_message.extend_from_slice(&payload);
    let mut verifier = Verifier::new_without_digest(&public_key).map_err(|_| UpdateError::InvalidSignature)?;
    let verified = verifier.verify_oneshot(&signature, &signed_message).map_err(|_| UpdateError::InvalidSignature)?;
    if !verified {
        return Err(UpdateError::InvalidSignature);
    }

    #[derive(Deserialize)]
    struct Header {
        schema: i64,
        #[serde(rename = "releaseNotesURL")]
        release_notes_url: String,
    }
    let header: Header = serde_json::from_slice(&payload).map_err(|_| UpdateError::InvalidPayload)?;
    if header.schema <= 0 {
        return Err(UpdateError::InvalidField("schema"));
    }
    validate_release_notes_url(&header.release_notes_url)?;
    if header.schema > 1 {
        return Ok(VerificationResult::RequiresManualUpdate {
            schema: u32::try_from(header.schema).unwrap_or(u32::MAX),
            release_notes_url: header.release_notes_url,
        });
    }

    let manifest: WindowsUpdateManifest = serde_json::from_slice(&payload).map_err(|_| UpdateError::InvalidPayload)?;
    manifest.validate(expected_app_id, allow_loopback_for_testing, repository)?;
    Ok(VerificationResult::Supported(manifest))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedHttpUrl {
    pub scheme: String,
    pub host: String,
    pub port: Option<u16>,
    pub path: String,
    pub query: Option<String>,
}

impl ParsedHttpUrl {
    pub fn effective_port(&self) -> u16 {
        self.port.unwrap_or(if self.scheme == "https" { 443 } else { 80 })
    }

    pub fn path_and_query(&self) -> String {
        match &self.query {
            Some(q) => format!("{}?{}", self.path, q),
            None => self.path.clone(),
        }
    }
}

pub fn parse_http_url(raw: &str) -> Result<ParsedHttpUrl, UpdateError> {
    if raw.is_empty() || raw.bytes().any(|b| b <= 0x20 || b >= 0x7F) || raw.contains('#') || raw.contains('\\') {
        return Err(UpdateError::UnsafeUrl);
    }
    let (scheme_raw, rest) = raw.split_once("://").ok_or(UpdateError::UnsafeUrl)?;
    let scheme = scheme_raw.to_ascii_lowercase();
    if scheme != "https" && scheme != "http" {
        return Err(UpdateError::UnsafeUrl);
    }
    let (authority, tail) = match rest.find(['/', '?']) {
        Some(idx) => (&rest[..idx], &rest[idx..]),
        None => (rest, "/"),
    };
    if authority.is_empty() || authority.contains('@') {
        return Err(UpdateError::UnsafeUrl);
    }
    let (host_raw, port) = if let Some((h, p)) = authority.rsplit_once(':') {
        if h.contains(':') {
            return Err(UpdateError::UnsafeUrl);
        }
        let parsed_port = p.parse::<u16>().map_err(|_| UpdateError::UnsafeUrl)?;
        if parsed_port == 0 {
            return Err(UpdateError::UnsafeUrl);
        }
        (h, Some(parsed_port))
    } else {
        (authority, None)
    };
    if host_raw.is_empty() {
        return Err(UpdateError::UnsafeUrl);
    }
    let host = host_raw.to_ascii_lowercase();
    let (path_raw, query) = match tail.split_once('?') {
        Some((p, q)) => (if p.is_empty() { "/" } else { p }, Some(q.to_string())),
        None => (tail, None),
    };
    if !path_raw.starts_with('/') {
        return Err(UpdateError::UnsafeUrl);
    }
    Ok(ParsedHttpUrl { scheme, host, port, path: path_raw.to_string(), query })
}

fn is_https(url: &ParsedHttpUrl) -> bool {
    url.scheme == "https" && !url.host.is_empty() && (url.port.is_none() || url.port == Some(443))
}

fn is_allowed_loopback(url: &ParsedHttpUrl, app_id: &str, enabled: bool) -> bool {
    enabled && !app_id.is_empty() && app_id != PRODUCTION_APP_ID && url.scheme == "http" && matches!(url.host.as_str(), "127.0.0.1" | "localhost")
}

pub fn valid_repository(value: &str) -> bool {
    let parts: Vec<&str> = value.split('/').collect();
    parts.len() == 2
        && parts
            .iter()
            .all(|part| !part.is_empty() && *part != "." && *part != ".." && part.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_')))
}

fn percent_decode_segment(segment: &str) -> Option<String> {
    let bytes = segment.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            let hi = (bytes[i + 1] as char).to_digit(16)?;
            let lo = (bytes[i + 2] as char).to_digit(16)?;
            out.push(((hi << 4) | lo) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

pub fn validate_release_notes_url(raw: &str) -> Result<ParsedHttpUrl, UpdateError> {
    let url = parse_http_url(raw)?;
    if !is_https(&url) || url.host != "github.com" {
        return Err(UpdateError::UnsafeUrl);
    }
    Ok(url)
}

pub fn validate_feed_url(raw: &str, app_id: &str, allow_loopback: bool) -> Result<ParsedHttpUrl, UpdateError> {
    let url = parse_http_url(raw)?;
    if is_allowed_loopback(&url, app_id, allow_loopback) {
        return Ok(url);
    }
    const SUFFIX: &str = "/releases/latest/download/QuietDesk-windows-update.json";
    if !is_https(&url) || url.host != "github.com" || url.query.is_some() || !url.path.ends_with(SUFFIX) {
        return Err(UpdateError::UnsafeUrl);
    }
    let repo = &url.path[1..url.path.len() - SUFFIX.len()];
    if !valid_repository(repo) {
        return Err(UpdateError::UnsafeUrl);
    }
    Ok(url)
}

pub fn repository_from_feed_url(raw: &str) -> Option<String> {
    let url = parse_http_url(raw).ok()?;
    const SUFFIX: &str = "/releases/latest/download/QuietDesk-windows-update.json";
    if is_https(&url) && url.host == "github.com" && url.query.is_none() && url.path.ends_with(SUFFIX) {
        let repo = &url.path[1..url.path.len() - SUFFIX.len()];
        if valid_repository(repo) {
            return Some(repo.to_string());
        }
    }
    None
}

pub fn validate_package_url(raw: &str, app_id: &str, allow_loopback: bool, repository: &str) -> Result<ParsedHttpUrl, UpdateError> {
    let url = parse_http_url(raw)?;
    if is_allowed_loopback(&url, app_id, allow_loopback) {
        return Ok(url);
    }
    if !is_https(&url) || url.host != "github.com" || !valid_repository(repository) {
        return Err(UpdateError::UnsafeUrl);
    }
    for segment in url.path[1..].split('/') {
        let Some(decoded) = percent_decode_segment(segment) else {
            return Err(UpdateError::UnsafeUrl);
        };
        if decoded.is_empty() || decoded == "." || decoded == ".." || decoded.contains('/') || decoded.contains('\\') {
            return Err(UpdateError::UnsafeUrl);
        }
    }
    let prefix = format!("/{repository}/releases/download/");
    let Some(rest) = url.path.strip_prefix(&prefix) else {
        return Err(UpdateError::UnsafeUrl);
    };
    if rest.split('/').filter(|s| !s.is_empty()).count() < 2 {
        return Err(UpdateError::UnsafeUrl);
    }
    Ok(url)
}

pub fn allows_redirect(raw: &str, app_id: &str, allow_loopback: bool) -> Result<ParsedHttpUrl, UpdateError> {
    let url = parse_http_url(raw)?;
    if is_https(&url) || is_allowed_loopback(&url, app_id, allow_loopback) { Ok(url) } else { Err(UpdateError::UnsafeUrl) }
}

pub struct Sha256Digest(Sha256);

impl Default for Sha256Digest {
    fn default() -> Self {
        Self::new()
    }
}

impl Sha256Digest {
    pub fn new() -> Self {
        Self(Sha256::new())
    }

    pub fn update(&mut self, chunk: &[u8]) {
        self.0.update(chunk);
    }

    pub fn finish_hex(self) -> String {
        let digest = self.0.finish();
        let mut text = String::with_capacity(64);
        for byte in digest {
            use std::fmt::Write;
            let _ = write!(&mut text, "{byte:02x}");
        }
        text
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut digest = Sha256Digest::new();
    digest.update(bytes);
    digest.finish_hex()
}

pub fn sign_manifest_for_testing(key_id: &str, manifest: &WindowsUpdateManifest) -> (UpdatePublicKey, Vec<u8>) {
    let key = PKey::generate_ed25519().expect("generate ed25519 key");
    let pub_key = UpdatePublicKey { id: key_id.to_string(), key: openssl::base64::encode_block(&key.raw_public_key().expect("raw public key")) };
    let payload = serde_json::to_vec(manifest).expect("serialize manifest");
    let mut msg = Vec::with_capacity(WINDOWS_SIGNING_PREFIX.len() + payload.len());
    msg.extend_from_slice(WINDOWS_SIGNING_PREFIX);
    msg.extend_from_slice(&payload);
    let mut signer = openssl::sign::Signer::new_without_digest(&key).expect("ed25519 signer");
    let sig = signer.sign_oneshot_to_vec(&msg).expect("sign manifest");
    let envelope = SignedUpdateEnvelope {
        format: 1,
        key_id: key_id.to_string(),
        payload: openssl::base64::encode_block(&payload),
        signature: openssl::base64::encode_block(&sig),
    };
    (pub_key, serde_json::to_vec(&envelope).expect("serialize envelope"))
}

pub fn build_portable_zip_for_testing(entries: &[(&str, &[u8])]) -> Vec<u8> {
    use flate2::Compression;
    use flate2::write::DeflateEncoder;
    use std::io::Write;

    let mut archive = Vec::new();
    let mut central = Vec::new();
    for &(name, content) in entries {
        let local_offset = archive.len() as u32;
        let mut crc = Crc32Hasher::new();
        crc.update(content);
        let crc_val = crc.finalize();
        let mut enc = DeflateEncoder::new(Vec::new(), Compression::default());
        enc.write_all(content).expect("deflate write");
        let payload = enc.finish().expect("deflate finish");

        archive.extend_from_slice(&0x0403_4B50u32.to_le_bytes());
        archive.extend_from_slice(&20u16.to_le_bytes());
        archive.extend_from_slice(&0u16.to_le_bytes());
        archive.extend_from_slice(&8u16.to_le_bytes());
        archive.extend_from_slice(&0u32.to_le_bytes());
        archive.extend_from_slice(&crc_val.to_le_bytes());
        archive.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        archive.extend_from_slice(&(content.len() as u32).to_le_bytes());
        archive.extend_from_slice(&(name.len() as u16).to_le_bytes());
        archive.extend_from_slice(&0u16.to_le_bytes());
        archive.extend_from_slice(name.as_bytes());
        archive.extend_from_slice(&payload);

        central.extend_from_slice(&0x0201_4B50u32.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&20u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&8u16.to_le_bytes());
        central.extend_from_slice(&0u32.to_le_bytes());
        central.extend_from_slice(&crc_val.to_le_bytes());
        central.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        central.extend_from_slice(&(content.len() as u32).to_le_bytes());
        central.extend_from_slice(&(name.len() as u16).to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u16.to_le_bytes());
        central.extend_from_slice(&0u32.to_le_bytes());
        central.extend_from_slice(&local_offset.to_le_bytes());
        central.extend_from_slice(name.as_bytes());
    }
    let central_offset = archive.len() as u32;
    let central_size = central.len() as u32;
    archive.extend_from_slice(&central);
    archive.extend_from_slice(&0x0605_4B50u32.to_le_bytes());
    archive.extend_from_slice(&0u16.to_le_bytes());
    archive.extend_from_slice(&0u16.to_le_bytes());
    archive.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    archive.extend_from_slice(&(entries.len() as u16).to_le_bytes());
    archive.extend_from_slice(&central_size.to_le_bytes());
    archive.extend_from_slice(&central_offset.to_le_bytes());
    archive.extend_from_slice(&0u16.to_le_bytes());
    archive
}

pub fn decode_base64_strict(input: &str) -> Option<Vec<u8>> {
    let bytes = input.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return None;
    }
    fn val(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let chunks = bytes.as_chunks::<4>().0;
    for (idx, chunk) in chunks.iter().enumerate() {
        let last = idx + 1 == chunks.len();
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        if chunk[2] == b'=' {
            if !last || chunk[3] != b'=' || (b & 0x0F) != 0 {
                return None;
            }
            out.push((a << 2) | (b >> 4));
        } else if chunk[3] == b'=' {
            if !last {
                return None;
            }
            let c = val(chunk[2])?;
            if (c & 0x03) != 0 {
                return None;
            }
            out.push((a << 2) | (b >> 4));
            out.push((b << 4) | (c >> 2));
        } else {
            let c = val(chunk[2])?;
            let d = val(chunk[3])?;
            out.push((a << 2) | (b >> 4));
            out.push((b << 4) | (c >> 2));
            out.push((c << 6) | d);
        }
    }
    Some(out)
}

fn valid_iso8601_timestamp(value: &str) -> bool {
    let b = value.as_bytes();
    if b.len() < 20 {
        return false;
    }
    let digits = |slice: &[u8]| -> Option<u32> { std::str::from_utf8(slice).ok().filter(|s| s.bytes().all(|c| c.is_ascii_digit()))?.parse().ok() };
    if b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
        return false;
    }
    let (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) =
        (digits(&b[0..4]), digits(&b[5..7]), digits(&b[8..10]), digits(&b[11..13]), digits(&b[14..16]), digits(&b[17..19]))
    else {
        return false;
    };
    let leap = (year.is_multiple_of(4) && !year.is_multiple_of(100)) || year.is_multiple_of(400);
    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    if day == 0 || day > max_day || hour > 23 || minute > 59 || second > 60 {
        return false;
    }
    let mut idx = 19;
    if idx < b.len() && b[idx] == b'.' {
        idx += 1;
        let start = idx;
        while idx < b.len() && b[idx].is_ascii_digit() {
            idx += 1;
        }
        if idx == start {
            return false;
        }
    }
    let tz = &b[idx..];
    if tz == b"Z" {
        return true;
    }
    if tz.len() == 6
        && matches!(tz[0], b'+' | b'-')
        && tz[3] == b':'
        && let (Some(th), Some(tm)) = (digits(&tz[1..3]), digits(&tz[4..6]))
    {
        return th <= 23 && tm <= 59;
    }
    false
}

pub fn inspect_pe(bytes: &[u8]) -> Result<(u16, u16, bool), UpdateError> {
    let bad = |msg: &str| UpdateError::InvalidExecutable(msg.to_string());
    if bytes.len() < 0x40 || &bytes[0..2] != b"MZ" {
        return Err(bad("更新文件不是有效的 Windows 可执行程序（缺少 MZ 头）"));
    }
    let pe_offset = u32::from_le_bytes([bytes[0x3C], bytes[0x3D], bytes[0x3E], bytes[0x3F]]) as usize;
    if pe_offset < 0x40 || pe_offset.saturating_add(24 + 70) > bytes.len() {
        return Err(bad("更新可执行程序的 PE 头偏移无效"));
    }
    if &bytes[pe_offset..pe_offset + 4] != b"PE\0\0" {
        return Err(bad("更新文件缺少有效的 PE 签名"));
    }
    let machine = u16::from_le_bytes([bytes[pe_offset + 4], bytes[pe_offset + 5]]);
    let optional_size = u16::from_le_bytes([bytes[pe_offset + 20], bytes[pe_offset + 21]]) as usize;
    let optional_offset = pe_offset + 24;
    if optional_size < 70 || optional_offset.saturating_add(optional_size) > bytes.len() {
        return Err(bad("更新可执行程序的 PE 可选头不完整"));
    }
    let magic = u16::from_le_bytes([bytes[optional_offset], bytes[optional_offset + 1]]);
    if magic != 0x010B && magic != 0x020B {
        return Err(bad("更新可执行程序的 PE 类型不受支持"));
    }
    let subsystem = u16::from_le_bytes([bytes[optional_offset + 68], bytes[optional_offset + 69]]);
    Ok((machine, subsystem, magic == 0x020B))
}

pub fn validate_pe_executable(bytes: &[u8], expected_arch: TargetArch) -> Result<(), UpdateError> {
    let (machine, subsystem, pe32_plus) = inspect_pe(bytes)?;
    if !pe32_plus || machine != expected_arch.pe_machine() {
        return Err(UpdateError::InvalidExecutable(format!("新版 QuietDesk.exe 处理器架构与当前程序（{}）不一致", expected_arch.as_str())));
    }
    if subsystem != IMAGE_SUBSYSTEM_WINDOWS_GUI {
        return Err(UpdateError::InvalidExecutable("新版 QuietDesk.exe 不是图形界面子系统程序".to_string()));
    }
    Ok(())
}

pub fn validate_pe_installer(bytes: &[u8]) -> Result<(), UpdateError> {
    let (machine, subsystem, _) = inspect_pe(bytes)?;
    if !matches!(machine, IMAGE_FILE_MACHINE_I386 | IMAGE_FILE_MACHINE_AMD64 | IMAGE_FILE_MACHINE_ARM64) {
        return Err(UpdateError::InvalidExecutable("更新安装程序处理器类型不受支持".to_string()));
    }
    if subsystem != IMAGE_SUBSYSTEM_WINDOWS_GUI {
        return Err(UpdateError::InvalidExecutable("更新安装程序不是 Windows 图形界面安装器".to_string()));
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExtractedPortableUpdate {
    pub executable: Vec<u8>,
    pub license: Option<Vec<u8>>,
    pub third_party_opus: Option<Vec<u8>>,
}

/// Strictly validates a portable Windows update ZIP and extracts `QuietDesk.exe` and optional license files.
pub fn extract_portable_zip(data: &[u8], expected_arch: TargetArch) -> Result<ExtractedPortableUpdate, UpdateError> {
    let bad = |msg: &str| UpdateError::InvalidArchive(msg.to_string());
    let u16_at = |offset: usize| -> Result<u16, UpdateError> {
        let slice = data.get(offset..offset + 2).ok_or_else(|| bad("更新 ZIP 包已截断"))?;
        Ok(u16::from_le_bytes([slice[0], slice[1]]))
    };
    let u32_at = |offset: usize| -> Result<u32, UpdateError> {
        let slice = data.get(offset..offset + 4).ok_or_else(|| bad("更新 ZIP 包已截断"))?;
        Ok(u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
    };

    if data.len() < 22 || data.len() as u64 > MAX_ARCHIVE_BYTES {
        return Err(bad("更新 ZIP 包大小无效"));
    }
    let min_eocd = data.len().saturating_sub(65_557);
    let mut eocd = None;
    for pos in (min_eocd..=data.len() - 22).rev() {
        if u32_at(pos)? == 0x0605_4B50 && pos + 22 + usize::from(u16_at(pos + 20)?) == data.len() {
            eocd = Some(pos);
            break;
        }
    }
    let Some(end) = eocd else {
        return Err(bad("更新 ZIP 包缺少中央目录结尾记录"));
    };
    let count = usize::from(u16_at(end + 10)?);
    if u16_at(end + 4)? != 0 || u16_at(end + 6)? != 0 || usize::from(u16_at(end + 8)?) != count || count == 0 || count >= 64 {
        return Err(bad("更新 ZIP 包目录条目数量不受支持"));
    }
    let central_size = u32_at(end + 12)? as usize;
    let central_start = u32_at(end + 16)? as usize;
    if central_size == 0 || central_start.saturating_add(central_size) != end {
        return Err(bad("更新 ZIP 包中央目录偏移无效"));
    }

    let mut cursor = central_start;
    let mut seen_names = HashSet::new();
    let mut local_ranges: Vec<(usize, usize)> = Vec::with_capacity(count);
    let mut total_uncompressed: u64 = 0;
    let mut executable = None;
    let mut license = None;
    let mut third_party_opus = None;

    for _ in 0..count {
        if u32_at(cursor)? != 0x0201_4B50 {
            return Err(bad("更新 ZIP 包中央目录头损坏"));
        }
        let flags = u16_at(cursor + 8)?;
        let method = u16_at(cursor + 10)?;
        let crc_expected = u32_at(cursor + 16)?;
        let compressed_size = u32_at(cursor + 20)? as usize;
        let uncompressed_size = u32_at(cursor + 24)? as usize;
        let name_len = usize::from(u16_at(cursor + 28)?);
        let extra_len = usize::from(u16_at(cursor + 30)?);
        let comment_len = usize::from(u16_at(cursor + 32)?);
        let disk_start = u16_at(cursor + 34)?;
        let local_offset = u32_at(cursor + 42)? as usize;

        // Disallow encryption (bit 0), data descriptor streaming (bit 3), and strong encryption (bit 6).
        if (flags & (1 | 8 | 64)) != 0 || (method != 0 && method != 8) || name_len == 0 || disk_start != 0 {
            return Err(bad("更新 ZIP 包使用了不支持的压缩或加密标志"));
        }
        let next_cursor = cursor
            .checked_add(46)
            .and_then(|v| v.checked_add(name_len))
            .and_then(|v| v.checked_add(extra_len))
            .and_then(|v| v.checked_add(comment_len))
            .ok_or_else(|| bad("更新 ZIP 包头长度溢出"))?;
        if next_cursor > end || local_offset.saturating_add(30) > central_start || u32_at(local_offset)? != 0x0403_4B50 {
            return Err(bad("更新 ZIP 包本地文件头无效"));
        }

        let raw_name = &data[cursor + 46..cursor + 46 + name_len];
        let name = std::str::from_utf8(raw_name).map_err(|_| bad("更新 ZIP 包文件名不是有效的 UTF-8"))?;
        if !matches!(name, "QuietDesk.exe" | "LICENSE" | "THIRD-PARTY-OPUS.txt") {
            return Err(bad(&format!("更新 ZIP 包包含未预期的文件：{name}")));
        }
        if !seen_names.insert(name.to_ascii_lowercase()) {
            return Err(bad("更新 ZIP 包包含重复文件条目"));
        }

        let local_flags = u16_at(local_offset + 6)?;
        let local_method = u16_at(local_offset + 8)?;
        let local_crc = u32_at(local_offset + 14)?;
        let local_compressed = u32_at(local_offset + 18)? as usize;
        let local_uncompressed = u32_at(local_offset + 22)? as usize;
        let local_name_len = usize::from(u16_at(local_offset + 26)?);
        let local_extra_len = usize::from(u16_at(local_offset + 28)?);
        let payload_start = local_offset
            .checked_add(30)
            .and_then(|v| v.checked_add(local_name_len))
            .and_then(|v| v.checked_add(local_extra_len))
            .ok_or_else(|| bad("更新 ZIP 包条目偏移溢出"))?;
        let payload_end = payload_start.checked_add(compressed_size).ok_or_else(|| bad("更新 ZIP 包负载长度溢出"))?;

        if local_flags != flags
            || local_method != method
            || local_crc != crc_expected
            || local_compressed != compressed_size
            || local_uncompressed != uncompressed_size
            || local_name_len != name_len
            || payload_end > central_start
            || &data[local_offset + 30..local_offset + 30 + local_name_len] != raw_name
            || (method == 0 && compressed_size != uncompressed_size)
        {
            return Err(bad("更新 ZIP 包本地头与中央目录不一致"));
        }

        total_uncompressed = total_uncompressed.saturating_add(uncompressed_size as u64);
        if total_uncompressed > MAX_EXTRACTED_BYTES {
            return Err(bad("更新 ZIP 包解压后超过大小上限"));
        }

        let compressed_slice = &data[payload_start..payload_end];
        let mut extracted = Vec::with_capacity(uncompressed_size.min(8 * 1024 * 1024));
        if method == 0 {
            extracted.extend_from_slice(compressed_slice);
        } else {
            let mut decoder = DeflateDecoder::new(compressed_slice).take((uncompressed_size as u64).saturating_add(1));
            decoder.read_to_end(&mut extracted).map_err(|_| bad("更新 ZIP 包解压失败"))?;
        }
        if extracted.len() != uncompressed_size {
            return Err(bad("更新 ZIP 包解压长度与头信息不符"));
        }
        let mut crc = Crc32Hasher::new();
        crc.update(&extracted);
        if crc.finalize() != crc_expected {
            return Err(bad("更新 ZIP 包 CRC-32 校验失败"));
        }

        match name {
            "QuietDesk.exe" => {
                validate_pe_executable(&extracted, expected_arch)?;
                executable = Some(extracted);
            }
            "LICENSE" => license = Some(extracted),
            "THIRD-PARTY-OPUS.txt" => third_party_opus = Some(extracted),
            _ => unreachable!(),
        }

        local_ranges.push((local_offset, payload_end));
        cursor = next_cursor;
    }

    if cursor != end {
        return Err(bad("更新 ZIP 包中央目录长度不匹配"));
    }
    local_ranges.sort_by_key(|r| r.0);
    for pair in local_ranges.windows(2) {
        if pair[0].1 > pair[1].0 {
            return Err(bad("更新 ZIP 包条目数据区间重叠"));
        }
    }
    let Some(executable) = executable else {
        return Err(bad("更新 ZIP 包缺少 QuietDesk.exe"));
    };
    Ok(ExtractedPortableUpdate { executable, license, third_party_opus })
}

pub mod policy {
    use super::{DAILY_CHECK_INTERVAL_SECS, FAILURE_RETRY_INTERVAL_SECS, POST_SESSION_COOLDOWN, STARTUP_CHECK_DELAY};
    use std::time::Duration;

    pub fn should_automatically_check(
        updater_enabled: bool,
        auto_check_enabled: bool,
        uptime: Duration,
        now_epoch_secs: u64,
        last_check_epoch_secs: Option<u64>,
        last_failed_epoch_secs: Option<u64>,
    ) -> bool {
        if !updater_enabled || !auto_check_enabled || uptime < STARTUP_CHECK_DELAY {
            return false;
        }
        if let Some(failed_at) = last_failed_epoch_secs
            && (now_epoch_secs < failed_at || now_epoch_secs - failed_at < FAILURE_RETRY_INTERVAL_SECS)
        {
            return false;
        }
        match last_check_epoch_secs {
            Some(checked_at) => now_epoch_secs >= checked_at && now_epoch_secs - checked_at >= DAILY_CHECK_INTERVAL_SECS,
            None => true,
        }
    }

    pub fn should_offer(version: &str, skipped_version: Option<&str>, manual: bool) -> bool {
        manual || skipped_version != Some(version)
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum AutoInstallBlockReason {
        Disabled,
        BeingRemotelyControlled,
        ControllingRemoteMachine,
        RecentSessionCooldown,
        BlockingPrompt,
        ManualOrElevatedInstallRequired,
        DeferredByUser,
    }

    impl AutoInstallBlockReason {
        pub fn is_session_deferral(self) -> bool {
            matches!(self, Self::BeingRemotelyControlled | Self::ControllingRemoteMachine | Self::RecentSessionCooldown | Self::BlockingPrompt)
        }

        pub fn deferral_message(self, version: Option<&str>, ready_to_install: bool) -> Option<String> {
            let label = version.map_or_else(|| "更新".to_string(), |v| format!("新版本 {v}"));
            let action = if ready_to_install { "自动安装并重启" } else { "自动下载并安装" };
            match self {
                Self::BeingRemotelyControlled => Some(format!("{label} 已待命 · 这台电脑正被远程控制，将在会话结束后{action}")),
                Self::ControllingRemoteMachine => Some(format!("{label} 已待命 · 正在远程控制其他电脑，将在窗口关闭后{action}")),
                Self::RecentSessionCooldown => Some(format!("{label} 已待命 · 远程会话刚结束，确认连接空闲后即将{action}…")),
                Self::BlockingPrompt => Some(format!("{label} 已待命 · 将在当前提示关闭后{action}")),
                Self::Disabled | Self::ManualOrElevatedInstallRequired | Self::DeferredByUser => None,
            }
        }
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum AutoInstallDecision {
        Proceed,
        Blocked(AutoInstallBlockReason),
    }

    #[derive(Clone, Copy, Debug, Default)]
    pub struct AutoInstallContext {
        pub updater_enabled: bool,
        pub auto_install_enabled: bool,
        pub has_host_connection: bool,
        pub viewer_count: usize,
        pub has_blocking_prompt: bool,
        pub needs_manual_or_elevated_install: bool,
        pub deferred_by_user: bool,
        pub since_last_remote_session: Option<Duration>,
    }

    pub fn is_remote_control_active(has_host_connection: bool, viewer_count: usize) -> bool {
        has_host_connection || viewer_count > 0
    }

    pub fn evaluate_auto_install(ctx: AutoInstallContext) -> AutoInstallDecision {
        if !ctx.updater_enabled || !ctx.auto_install_enabled {
            return AutoInstallDecision::Blocked(AutoInstallBlockReason::Disabled);
        }
        if ctx.needs_manual_or_elevated_install {
            return AutoInstallDecision::Blocked(AutoInstallBlockReason::ManualOrElevatedInstallRequired);
        }
        if ctx.deferred_by_user {
            return AutoInstallDecision::Blocked(AutoInstallBlockReason::DeferredByUser);
        }
        if ctx.has_host_connection {
            return AutoInstallDecision::Blocked(AutoInstallBlockReason::BeingRemotelyControlled);
        }
        if ctx.viewer_count > 0 {
            return AutoInstallDecision::Blocked(AutoInstallBlockReason::ControllingRemoteMachine);
        }
        if let Some(elapsed) = ctx.since_last_remote_session
            && elapsed < POST_SESSION_COOLDOWN
        {
            return AutoInstallDecision::Blocked(AutoInstallBlockReason::RecentSessionCooldown);
        }
        if ctx.has_blocking_prompt {
            return AutoInstallDecision::Blocked(AutoInstallBlockReason::BlockingPrompt);
        }
        AutoInstallDecision::Proceed
    }

    pub fn download_retry_delay(attempt: u32) -> Duration {
        match attempt.max(1) {
            1 => Duration::from_secs(5 * 60),
            2 => Duration::from_secs(15 * 60),
            _ => Duration::from_secs(60 * 60),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::policy::*;
    use super::*;
    use flate2::Compression;
    use flate2::write::DeflateEncoder;
    use openssl::sign::Signer;
    use std::io::Write;

    fn encode_base64(bytes: &[u8]) -> String {
        openssl::base64::encode_block(bytes)
    }

    fn generate_keypair(id: &str) -> (PKey<openssl::pkey::Private>, UpdatePublicKey) {
        let key = PKey::generate_ed25519().expect("generate ed25519");
        let raw_pub = key.raw_public_key().expect("raw public key");
        let pub_entry = UpdatePublicKey { id: id.to_string(), key: encode_base64(&raw_pub) };
        (key, pub_entry)
    }

    fn sign_bytes(key: &PKey<openssl::pkey::Private>, prefix: &[u8], payload: &[u8], key_id: &str) -> Vec<u8> {
        let mut msg = Vec::with_capacity(prefix.len() + payload.len());
        msg.extend_from_slice(prefix);
        msg.extend_from_slice(payload);
        let mut signer = Signer::new_without_digest(key).expect("signer");
        let sig = signer.sign_oneshot_to_vec(&msg).expect("sign");
        let env = SignedUpdateEnvelope { format: 1, key_id: key_id.to_string(), payload: encode_base64(payload), signature: encode_base64(&sig) };
        serde_json::to_vec(&env).expect("serialize envelope")
    }

    fn sample_manifest() -> WindowsUpdateManifest {
        let mut packages = BTreeMap::new();
        packages.insert(
            "x64".to_string(),
            WindowsArchPackages {
                portable: UpdateArchive {
                    url: "https://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/QuietDesk-0.8.0-Windows-x64.zip".into(),
                    size: 4_100_000,
                    sha256: "a".repeat(64),
                },
                installer: Some(UpdateArchive {
                    url: "https://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/QuietDesk-0.8.0-Windows-x64-Setup.exe".into(),
                    size: 5_200_000,
                    sha256: "b".repeat(64),
                }),
            },
        );
        packages.insert(
            "arm64".to_string(),
            WindowsArchPackages {
                portable: UpdateArchive {
                    url: "https://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/QuietDesk-0.8.0-Windows-arm64.zip".into(),
                    size: 3_950_000,
                    sha256: "c".repeat(64),
                },
                installer: Some(UpdateArchive {
                    url: "https://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/QuietDesk-0.8.0-Windows-arm64-Setup.exe".into(),
                    size: 5_010_000,
                    sha256: "d".repeat(64),
                }),
            },
        );
        WindowsUpdateManifest {
            schema: 1,
            app_id: PRODUCTION_APP_ID.into(),
            version: "0.8.0".into(),
            build: 31,
            published_at: "2026-11-23T08:30:00Z".into(),
            revision: "e".repeat(40),
            release_notes_url: "https://github.com/nXiaoK/QuietDesk/releases/tag/v0.8.0".into(),
            notes: Some("支持 Windows 应用内自动更新".into()),
            packages,
        }
    }

    fn synthetic_pe(machine: u16, subsystem: u16, pe32_plus: bool) -> Vec<u8> {
        let mut out = vec![0u8; 0x80];
        out[0..2].copy_from_slice(b"MZ");
        out[0x3C..0x40].copy_from_slice(&(0x80u32).to_le_bytes());
        out.extend_from_slice(b"PE\0\0");
        let opt_size: u16 = if pe32_plus { 0xF0 } else { 0xE0 };
        out.extend_from_slice(&machine.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&[0u8; 12]);
        out.extend_from_slice(&opt_size.to_le_bytes());
        out.extend_from_slice(&0x0022u16.to_le_bytes());
        let mut opt = vec![0u8; usize::from(opt_size)];
        let magic: u16 = if pe32_plus { 0x020B } else { 0x010B };
        opt[0..2].copy_from_slice(&magic.to_le_bytes());
        opt[68..70].copy_from_slice(&subsystem.to_le_bytes());
        out.extend_from_slice(&opt);
        out.extend_from_slice(&[0u8; 64]);
        out
    }

    fn build_zip(entries: &[(&str, &[u8], bool)]) -> Vec<u8> {
        let mut archive = Vec::new();
        let mut central = Vec::new();
        for &(name, content, deflate) in entries {
            let local_offset = archive.len() as u32;
            let mut crc = Crc32Hasher::new();
            crc.update(content);
            let crc_val = crc.finalize();
            let (method, payload) = if deflate {
                let mut enc = DeflateEncoder::new(Vec::new(), Compression::default());
                enc.write_all(content).unwrap();
                (8u16, enc.finish().unwrap())
            } else {
                (0u16, content.to_vec())
            };
            archive.extend_from_slice(&0x0403_4B50u32.to_le_bytes());
            archive.extend_from_slice(&20u16.to_le_bytes());
            archive.extend_from_slice(&0u16.to_le_bytes());
            archive.extend_from_slice(&method.to_le_bytes());
            archive.extend_from_slice(&0u32.to_le_bytes());
            archive.extend_from_slice(&crc_val.to_le_bytes());
            archive.extend_from_slice(&(payload.len() as u32).to_le_bytes());
            archive.extend_from_slice(&(content.len() as u32).to_le_bytes());
            archive.extend_from_slice(&(name.len() as u16).to_le_bytes());
            archive.extend_from_slice(&0u16.to_le_bytes());
            archive.extend_from_slice(name.as_bytes());
            archive.extend_from_slice(&payload);

            central.extend_from_slice(&0x0201_4B50u32.to_le_bytes());
            central.extend_from_slice(&20u16.to_le_bytes());
            central.extend_from_slice(&20u16.to_le_bytes());
            central.extend_from_slice(&0u16.to_le_bytes());
            central.extend_from_slice(&method.to_le_bytes());
            central.extend_from_slice(&0u32.to_le_bytes());
            central.extend_from_slice(&crc_val.to_le_bytes());
            central.extend_from_slice(&(payload.len() as u32).to_le_bytes());
            central.extend_from_slice(&(content.len() as u32).to_le_bytes());
            central.extend_from_slice(&(name.len() as u16).to_le_bytes());
            central.extend_from_slice(&0u16.to_le_bytes());
            central.extend_from_slice(&0u16.to_le_bytes());
            central.extend_from_slice(&0u16.to_le_bytes());
            central.extend_from_slice(&0u16.to_le_bytes());
            central.extend_from_slice(&0u32.to_le_bytes());
            central.extend_from_slice(&local_offset.to_le_bytes());
            central.extend_from_slice(name.as_bytes());
        }
        let central_offset = archive.len() as u32;
        let central_size = central.len() as u32;
        archive.extend_from_slice(&central);
        archive.extend_from_slice(&0x0605_4B50u32.to_le_bytes());
        archive.extend_from_slice(&0u16.to_le_bytes());
        archive.extend_from_slice(&0u16.to_le_bytes());
        archive.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        archive.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        archive.extend_from_slice(&central_size.to_le_bytes());
        archive.extend_from_slice(&central_offset.to_le_bytes());
        archive.extend_from_slice(&0u16.to_le_bytes());
        archive
    }

    #[test]
    fn authenticates_payload_bytes_and_rejects_domain_replay_or_tampering() {
        let (key, pub_key) = generate_keypair("2026-10");
        let manifest = sample_manifest();
        let payload = serde_json::to_vec(&manifest).unwrap();
        let data = sign_bytes(&key, WINDOWS_SIGNING_PREFIX, &payload, "2026-10");
        assert_eq!(
            verify_manifest(&data, std::slice::from_ref(&pub_key), PRODUCTION_APP_ID, false, "nXiaoK/QuietDesk").unwrap(),
            VerificationResult::Supported(manifest.clone())
        );

        let mac_domain = sign_bytes(&key, b"QuietDesk-update-v1\n", &payload, "2026-10");
        assert_eq!(
            verify_manifest(&mac_domain, std::slice::from_ref(&pub_key), PRODUCTION_APP_ID, false, "nXiaoK/QuietDesk"),
            Err(UpdateError::InvalidSignature)
        );

        for offset in (0..payload.len()).step_by(7) {
            let mut flipped = payload.clone();
            flipped[offset] ^= 0x01;
            let mut env: SignedUpdateEnvelope = serde_json::from_slice(&data).unwrap();
            env.payload = encode_base64(&flipped);
            let tampered = serde_json::to_vec(&env).unwrap();
            assert_eq!(
                verify_manifest(&tampered, std::slice::from_ref(&pub_key), PRODUCTION_APP_ID, false, "nXiaoK/QuietDesk"),
                Err(UpdateError::InvalidSignature)
            );
        }

        let future = serde_json::json!({
            "schema": 2,
            "releaseNotesURL": "https://github.com/nXiaoK/QuietDesk/releases/latest",
            "futureFlag": true
        });
        let future_signed = sign_bytes(&key, WINDOWS_SIGNING_PREFIX, &serde_json::to_vec(&future).unwrap(), "2026-10");
        assert_eq!(
            verify_manifest(&future_signed, std::slice::from_ref(&pub_key), PRODUCTION_APP_ID, false, "nXiaoK/QuietDesk").unwrap(),
            VerificationResult::RequiresManualUpdate { schema: 2, release_notes_url: "https://github.com/nXiaoK/QuietDesk/releases/latest".into() }
        );
    }

    #[test]
    fn versions_and_urls_enforce_anti_downgrade_and_repository_isolation() {
        assert!(UpdateVersion::parse("1.10.0").unwrap() > UpdateVersion::parse("1.9.99").unwrap());
        assert!(UpdateVersion::parse("999999999999999999999999.0.0").unwrap() > UpdateVersion::parse("999999999999999999999998.9.9").unwrap());
        for bad in ["", "1.2", "01.2.3", "1.2.3-rc1", "1.2.3.4"] {
            assert!(UpdateVersion::parse(bad).is_err(), "{bad}");
        }
        let manifest = sample_manifest();
        assert_eq!(manifest.assess("0.7.3", 25, TargetArch::X64).unwrap(), UpdateAvailability::Available);
        assert_eq!(manifest.assess("0.7.3", 25, TargetArch::Arm64).unwrap(), UpdateAvailability::Available);
        assert_eq!(manifest.assess("0.8.0", 31, TargetArch::X64).unwrap(), UpdateAvailability::UpToDate);
        assert_eq!(manifest.assess("0.7.3", 31, TargetArch::X64).unwrap(), UpdateAvailability::InconsistentBuild);

        for unsafe_url in [
            "http://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/a.zip",
            "https://github.com/other/QuietDesk/releases/download/v0.8.0/a.zip",
            "https://user:pass@github.com/nXiaoK/QuietDesk/releases/download/v0.8.0/a.zip",
            "https://github.com/nXiaoK/QuietDesk/releases/download/%2e%2e/other/a.zip",
            "https://github.com/nXiaoK/QuietDesk/releases/download/v0.8.0%2f..%2fother/a.zip",
        ] {
            assert!(validate_package_url(unsafe_url, PRODUCTION_APP_ID, false, "nXiaoK/QuietDesk").is_err(), "{unsafe_url}");
        }
        assert!(validate_package_url("http://127.0.0.1:8080/a.zip", PRODUCTION_APP_ID, true, "nXiaoK/QuietDesk").is_err());
        assert!(validate_package_url("http://127.0.0.1:8080/a.zip", "QuietDesk.Windows.Checks", true, "nXiaoK/QuietDesk").is_ok());
        assert!(allows_redirect("https://objects.githubusercontent.com/github-production-release-asset/1", PRODUCTION_APP_ID, false).is_ok());
        assert!(allows_redirect("http://objects.githubusercontent.com/1", PRODUCTION_APP_ID, false).is_err());
    }

    #[test]
    fn portable_zip_validates_crc_architecture_and_allowed_entries() {
        let x64_exe = synthetic_pe(IMAGE_FILE_MACHINE_AMD64, IMAGE_SUBSYSTEM_WINDOWS_GUI, true);
        let arm64_exe = synthetic_pe(IMAGE_FILE_MACHINE_ARM64, IMAGE_SUBSYSTEM_WINDOWS_GUI, true);
        let zip = build_zip(&[("QuietDesk.exe", &x64_exe, true), ("LICENSE", b"MIT License\n", false), ("THIRD-PARTY-OPUS.txt", b"Opus BSD\n", true)]);
        let extracted = extract_portable_zip(&zip, TargetArch::X64).expect("valid x64 portable zip");
        assert_eq!(extracted.executable, x64_exe);
        assert_eq!(extracted.license.as_deref(), Some(b"MIT License\n".as_slice()));
        assert!(extract_portable_zip(&zip, TargetArch::Arm64).is_err(), "wrong arch must fail");

        let arm_zip = build_zip(&[("QuietDesk.exe", &arm64_exe, true)]);
        assert_eq!(extract_portable_zip(&arm_zip, TargetArch::Arm64).unwrap().executable, arm64_exe);

        let traversal_zip = build_zip(&[("QuietDesk.exe", &x64_exe, true), ("../evil.dll", b"bad", false)]);
        assert!(extract_portable_zip(&traversal_zip, TargetArch::X64).is_err());

        let mut corrupted = zip.clone();
        let mid = corrupted.len() / 2;
        corrupted[mid] ^= 0xFF;
        assert!(extract_portable_zip(&corrupted, TargetArch::X64).is_err());
    }

    #[test]
    fn idle_auto_install_policy_defers_active_sessions_and_honors_cooldown() {
        let base = AutoInstallContext { updater_enabled: true, auto_install_enabled: true, ..Default::default() };
        assert_eq!(evaluate_auto_install(base), AutoInstallDecision::Proceed);
        assert_eq!(
            evaluate_auto_install(AutoInstallContext { has_host_connection: true, ..base }),
            AutoInstallDecision::Blocked(AutoInstallBlockReason::BeingRemotelyControlled)
        );
        assert_eq!(
            evaluate_auto_install(AutoInstallContext { viewer_count: 1, ..base }),
            AutoInstallDecision::Blocked(AutoInstallBlockReason::ControllingRemoteMachine)
        );
        assert_eq!(
            evaluate_auto_install(AutoInstallContext { since_last_remote_session: Some(Duration::from_secs(9)), ..base }),
            AutoInstallDecision::Blocked(AutoInstallBlockReason::RecentSessionCooldown)
        );
        assert_eq!(
            evaluate_auto_install(AutoInstallContext { since_last_remote_session: Some(Duration::from_secs(10)), ..base }),
            AutoInstallDecision::Proceed
        );
        assert!(!should_automatically_check(true, true, Duration::from_secs(119), 200_000, None, None));
        assert!(should_automatically_check(true, true, Duration::from_secs(120), 200_000, None, None));
        assert!(!should_automatically_check(true, true, Duration::from_secs(300), 200_000, Some(200_000 - 86_399), None));
        assert!(should_automatically_check(true, true, Duration::from_secs(300), 200_000, Some(200_000 - 86_400), None));
    }
}
