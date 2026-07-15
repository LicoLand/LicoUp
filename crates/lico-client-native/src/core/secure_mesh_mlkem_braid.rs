//! Signal ML-KEM Braid Revision 1 SCKA for the secure-mesh client.
//!
//! Clean-room implementation from the public Signal specification. The relay
//! transports only protocol messages and never receives state or output keys.

use std::{collections::BTreeMap, mem};

use anyhow::{Context, Result, anyhow, bail, ensure};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use libcrux_ml_kem::{
    KEY_GENERATION_SEED_SIZE,
    mlkem1024::incremental::{self, Ciphertext1, Ciphertext2},
};
use rand::{CryptoRng, RngCore, rngs::OsRng};
use serde::{Deserialize, Deserializer, Serialize, Serializer, de};
use sha2::Sha256;
use zeroize::{Zeroize, Zeroizing};

pub const ML_KEM_BRAID_CHUNK_BYTES: usize = 32;
pub const ML_KEM_BRAID_HEADER_BYTES: usize = 64;
pub const ML_KEM_BRAID_EK_BYTES: usize = 1_536;
pub const ML_KEM_BRAID_CT1_BYTES: usize = 1_408;
pub const ML_KEM_BRAID_CT2_BYTES: usize = 160;
pub const ML_KEM_BRAID_MAC_BYTES: usize = 32;
pub const ML_KEM_BRAID_TRANSITION_COUNT: usize = 13;

const _: [(); ML_KEM_BRAID_HEADER_BYTES] = [(); incremental::pk1_len()];
const _: [(); ML_KEM_BRAID_EK_BYTES] = [(); incremental::pk2_len()];
const _: [(); ML_KEM_BRAID_CT1_BYTES] = [(); Ciphertext1::len()];
const _: [(); ML_KEM_BRAID_CT2_BYTES] = [(); Ciphertext2::len()];

const PROTOCOL_INFO: &[u8] = b"LicoLite_MLKEM1024_HMAC-SHA256";
const AUTH_UPDATE_LABEL: &[u8] = b":Authenticator Update";
const OUTPUT_KEY_LABEL: &[u8] = b":SCKA Key";
const HEADER_MAC_LABEL: &[u8] = b":ekheader";
const CIPHERTEXT_MAC_LABEL: &[u8] = b":ciphertext";
const INITIAL_EPOCH: u64 = 1;
const MAX_SOURCE_CHUNKS: usize = ML_KEM_BRAID_EK_BYTES / ML_KEM_BRAID_CHUNK_BYTES;
const GF_REDUCTION_POLYNOMIAL: u32 = 0x100b;
const PERSISTENCE_REVISION: u8 = 2;
const MAX_PERSISTED_SESSION_BYTES: usize = 512 * 1024;
const ENCODED_CHUNK_BYTES: usize = ((ML_KEM_BRAID_CHUNK_BYTES + 2) * 8 + 5) / 6;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum MlKemBraidMessageType {
    #[serde(rename = "None")]
    None,
    #[serde(rename = "Hdr")]
    Hdr,
    #[serde(rename = "Ek")]
    Ek,
    #[serde(rename = "EkCt1Ack")]
    EkCt1Ack,
    #[serde(rename = "Ct1Ack")]
    Ct1Ack,
    #[serde(rename = "Ct1")]
    Ct1,
    #[serde(rename = "Ct2")]
    Ct2,
}

impl MlKemBraidMessageType {
    fn carries_data(self) -> bool {
        !matches!(self, Self::None | Self::Ct1Ack)
    }
}

/// One systematic GF(2^16) codeword, including its two-byte evaluation point.
#[derive(Clone, Eq, PartialEq)]
pub struct MlKemBraidChunk {
    point: u16,
    bytes: [u8; ML_KEM_BRAID_CHUNK_BYTES],
}

impl MlKemBraidChunk {
    pub fn point(&self) -> u16 {
        self.point
    }

    pub fn bytes(&self) -> &[u8; ML_KEM_BRAID_CHUNK_BYTES] {
        &self.bytes
    }

    fn new(point: u16, bytes: [u8; ML_KEM_BRAID_CHUNK_BYTES]) -> Self {
        Self { point, bytes }
    }
}

impl Serialize for MlKemBraidChunk {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let mut encoded = [0u8; ML_KEM_BRAID_CHUNK_BYTES + 2];
        encoded[..2].copy_from_slice(&self.point.to_be_bytes());
        encoded[2..].copy_from_slice(&self.bytes);
        serializer.serialize_str(&URL_SAFE_NO_PAD.encode(encoded))
    }
}

impl<'de> Deserialize<'de> for MlKemBraidChunk {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        if encoded.len() != ENCODED_CHUNK_BYTES {
            return Err(de::Error::custom("ML-KEM Braid data length is invalid"));
        }
        let mut decoded = [0u8; ML_KEM_BRAID_CHUNK_BYTES + 2];
        let decoded_len = URL_SAFE_NO_PAD
            .decode_slice(encoded.as_bytes(), &mut decoded)
            .map_err(de::Error::custom)?;
        if decoded_len != decoded.len() || URL_SAFE_NO_PAD.encode(decoded) != encoded {
            return Err(de::Error::custom(
                "ML-KEM Braid data encoding is non-canonical",
            ));
        }
        let point = u16::from_be_bytes([decoded[0], decoded[1]]);
        let mut bytes = [0u8; ML_KEM_BRAID_CHUNK_BYTES];
        bytes.copy_from_slice(&decoded[2..]);
        Ok(Self { point, bytes })
    }
}

/// Strict wire representation with exactly epoch, type, and optional data.
#[derive(Clone, Eq, PartialEq, Serialize)]
pub struct MlKemBraidMessage {
    epoch: u64,
    #[serde(rename = "type")]
    message_type: MlKemBraidMessageType,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<MlKemBraidChunk>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawMlKemBraidMessage {
    epoch: u64,
    #[serde(rename = "type")]
    message_type: MlKemBraidMessageType,
    #[serde(default)]
    data: Option<MlKemBraidChunk>,
}

impl<'de> Deserialize<'de> for MlKemBraidMessage {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawMlKemBraidMessage::deserialize(deserializer)?;
        let message = Self {
            epoch: raw.epoch,
            message_type: raw.message_type,
            data: raw.data,
        };
        message.validate().map_err(de::Error::custom)?;
        Ok(message)
    }
}

impl MlKemBraidMessage {
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    pub fn message_type(&self) -> MlKemBraidMessageType {
        self.message_type
    }

    pub fn data(&self) -> Option<&MlKemBraidChunk> {
        self.data.as_ref()
    }

    fn payload(epoch: u64, message_type: MlKemBraidMessageType, data: MlKemBraidChunk) -> Self {
        Self {
            epoch,
            message_type,
            data: Some(data),
        }
    }

    fn empty(epoch: u64, message_type: MlKemBraidMessageType) -> Self {
        Self {
            epoch,
            message_type,
            data: None,
        }
    }

    fn validate(&self) -> Result<()> {
        ensure!(self.epoch != 0, "ML-KEM Braid epoch zero is invalid");
        ensure!(
            self.message_type.carries_data() == self.data.is_some(),
            "ML-KEM Braid type/data combination is invalid"
        );
        Ok(())
    }
}

/// Newly emitted SCKA output. Secrets deliberately have no Debug or serde.
pub(crate) struct MlKemBraidOutputKey {
    epoch: u64,
    key: Zeroizing<[u8; 32]>,
}

impl MlKemBraidOutputKey {
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    pub fn key(&self) -> &[u8; 32] {
        &self.key
    }
}

pub(crate) struct MlKemBraidSend {
    pub message: MlKemBraidMessage,
    pub sending_epoch: u64,
    pub output_key: Option<MlKemBraidOutputKey>,
}

pub(crate) struct MlKemBraidReceive {
    pub receiving_epoch: u64,
    pub output_key: Option<MlKemBraidOutputKey>,
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MlKemBraidStateName {
    KeysUnsampled,
    KeysSampled,
    HeaderSent,
    Ct1Received,
    EkSentCt1Received,
    NoHeaderReceived,
    HeaderReceived,
    Ct1Sampled,
    EkReceivedCt1Sampled,
    Ct1Acknowledged,
    Ct2Sampled,
    Poisoned,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(transparent)]
struct SecretBytes(Vec<u8>);

impl SecretBytes {
    fn new(value: Vec<u8>) -> Self {
        Self(value)
    }

    fn as_slice(&self) -> &[u8] {
        &self.0
    }

    fn ensure_len(&self, expected: usize) -> Result<()> {
        ensure!(
            self.0.len() == expected,
            "persisted ML-KEM Braid secret length is invalid"
        );
        Ok(())
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RatchetedAuthenticator {
    root_key: SecretBytes,
    mac_key: SecretBytes,
}

impl RatchetedAuthenticator {
    fn initialize(epoch: u64, key: &[u8]) -> Result<Self> {
        let mut auth = Self {
            root_key: SecretBytes::new(vec![0u8; 32]),
            mac_key: SecretBytes::new(vec![0u8; 32]),
        };
        auth.update(epoch, key)?;
        Ok(auth)
    }

    fn update(&mut self, epoch: u64, key: &[u8]) -> Result<()> {
        let mut info = Vec::with_capacity(PROTOCOL_INFO.len() + AUTH_UPDATE_LABEL.len() + 8);
        info.extend_from_slice(PROTOCOL_INFO);
        info.extend_from_slice(AUTH_UPDATE_LABEL);
        info.extend_from_slice(&epoch.to_be_bytes());
        let mut expanded = Zeroizing::new([0u8; 64]);
        Hkdf::<Sha256>::new(Some(self.root_key.as_slice()), key)
            .expand(&info, expanded.as_mut())
            .map_err(|_| anyhow!("ML-KEM Braid authenticator KDF failed"))?;
        self.root_key.0.copy_from_slice(&expanded[..32]);
        self.mac_key.0.copy_from_slice(&expanded[32..]);
        Ok(())
    }

    fn mac_header(&self, epoch: u64, header: &[u8]) -> Result<[u8; 32]> {
        self.mac(HEADER_MAC_LABEL, epoch, header)
    }

    fn mac_ciphertext(&self, epoch: u64, ciphertext: &[u8]) -> Result<[u8; 32]> {
        self.mac(CIPHERTEXT_MAC_LABEL, epoch, ciphertext)
    }

    fn verify_header(&self, epoch: u64, header: &[u8], expected: &[u8]) -> Result<()> {
        self.verify(HEADER_MAC_LABEL, epoch, header, expected)
    }

    fn verify_ciphertext(&self, epoch: u64, ciphertext: &[u8], expected: &[u8]) -> Result<()> {
        self.verify(CIPHERTEXT_MAC_LABEL, epoch, ciphertext, expected)
    }

    fn mac(&self, label: &[u8], epoch: u64, body: &[u8]) -> Result<[u8; 32]> {
        let mut mac = <HmacSha256 as Mac>::new_from_slice(self.mac_key.as_slice())
            .map_err(|_| anyhow!("ML-KEM Braid MAC key is invalid"))?;
        mac.update(PROTOCOL_INFO);
        mac.update(label);
        mac.update(&epoch.to_be_bytes());
        mac.update(body);
        let mut output = [0u8; 32];
        output.copy_from_slice(&mac.finalize().into_bytes());
        Ok(output)
    }

    fn verify(&self, label: &[u8], epoch: u64, body: &[u8], expected: &[u8]) -> Result<()> {
        ensure!(
            expected.len() == ML_KEM_BRAID_MAC_BYTES,
            "ML-KEM Braid MAC length is invalid"
        );
        let mut mac = <HmacSha256 as Mac>::new_from_slice(self.mac_key.as_slice())
            .map_err(|_| anyhow!("ML-KEM Braid MAC key is invalid"))?;
        mac.update(PROTOCOL_INFO);
        mac.update(label);
        mac.update(&epoch.to_be_bytes());
        mac.update(body);
        mac.verify_slice(expected)
            .map_err(|_| anyhow!("ML-KEM Braid authentication failed"))
    }

    fn validate(&self) -> Result<()> {
        self.root_key.ensure_len(32)?;
        self.mac_key.ensure_len(32)
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ErasureEncoder {
    source: Vec<Vec<u8>>,
    next_point: u32,
    #[serde(skip)]
    denominator_inverses: Vec<u16>,
}

impl ErasureEncoder {
    fn new(message: &[u8]) -> Result<Self> {
        ensure!(
            !message.is_empty() && message.len().is_multiple_of(ML_KEM_BRAID_CHUNK_BYTES),
            "ML-KEM Braid erasure message size is invalid"
        );
        let source = message
            .chunks_exact(ML_KEM_BRAID_CHUNK_BYTES)
            .map(|chunk| chunk.to_vec())
            .collect::<Vec<_>>();
        ensure!(
            source.len() <= MAX_SOURCE_CHUNKS,
            "ML-KEM Braid erasure message exceeds the resource limit"
        );
        let mut encoder = Self {
            source,
            next_point: 0,
            denominator_inverses: Vec::new(),
        };
        encoder.rebuild_cache()?;
        Ok(encoder)
    }

    fn next_chunk(&mut self) -> Result<MlKemBraidChunk> {
        ensure!(
            self.next_point <= u16::MAX as u32,
            "ML-KEM Braid erasure domain is exhausted"
        );
        let point = self.next_point as u16;
        let bytes = self.evaluate(point)?;
        self.next_point = self
            .next_point
            .checked_add(1)
            .ok_or_else(|| anyhow!("ML-KEM Braid erasure point overflow"))?;
        Ok(MlKemBraidChunk::new(point, bytes))
    }

    fn message_bytes(&self) -> usize {
        self.source.len() * ML_KEM_BRAID_CHUNK_BYTES
    }

    fn evaluate(&self, point: u16) -> Result<[u8; ML_KEM_BRAID_CHUNK_BYTES]> {
        let source_count = self.source.len();
        if usize::from(point) < source_count {
            return self.source[usize::from(point)]
                .as_slice()
                .try_into()
                .map_err(|_| anyhow!("ML-KEM Braid source chunk length is invalid"));
        }
        let mut coefficients = Vec::with_capacity(source_count);
        for source_point in 0..source_count {
            let mut numerator = 1u16;
            for other in 0..source_count {
                if other != source_point {
                    numerator = gf_mul(numerator, point ^ other as u16);
                }
            }
            coefficients.push(gf_mul(numerator, self.denominator_inverses[source_point]));
        }
        Ok(combine_codewords(&self.source, &coefficients))
    }

    fn rebuild_cache(&mut self) -> Result<()> {
        ensure!(
            !self.source.is_empty() && self.source.len() <= MAX_SOURCE_CHUNKS,
            "persisted ML-KEM Braid encoder source count is invalid"
        );
        ensure!(
            self.source
                .iter()
                .all(|chunk| chunk.len() == ML_KEM_BRAID_CHUNK_BYTES),
            "persisted ML-KEM Braid encoder chunk length is invalid"
        );
        ensure!(
            self.next_point <= u16::MAX as u32 + 1,
            "persisted ML-KEM Braid encoder point is invalid"
        );
        let mut denominators = Vec::with_capacity(self.source.len());
        for point in 0..self.source.len() {
            let mut denominator = 1u16;
            for other in 0..self.source.len() {
                if other != point {
                    denominator = gf_mul(denominator, point as u16 ^ other as u16);
                }
            }
            denominators.push(denominator);
        }
        self.denominator_inverses = batch_inverse(&denominators)?;
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ErasureDecoder {
    message_bytes: usize,
    #[serde(with = "u16_chunk_map")]
    chunks: BTreeMap<u16, Vec<u8>>,
    decoded: Option<Vec<u8>>,
}

mod u16_chunk_map {
    use std::collections::BTreeMap;

    use serde::{Deserialize, Deserializer, Serialize, Serializer, de};

    pub fn serialize<S>(chunks: &BTreeMap<u16, Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        chunks
            .iter()
            .map(|(point, bytes)| (*point, bytes))
            .collect::<Vec<_>>()
            .serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<BTreeMap<u16, Vec<u8>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let entries = Vec::<(u16, Vec<u8>)>::deserialize(deserializer)?;
        let mut chunks = BTreeMap::new();
        for (point, bytes) in entries {
            if chunks.insert(point, bytes).is_some() {
                return Err(de::Error::custom(
                    "ML-KEM Braid persisted decoder point is duplicated",
                ));
            }
        }
        Ok(chunks)
    }
}

impl ErasureDecoder {
    fn new(message_bytes: usize) -> Result<Self> {
        ensure!(
            message_bytes != 0 && message_bytes.is_multiple_of(ML_KEM_BRAID_CHUNK_BYTES),
            "ML-KEM Braid decoder message size is invalid"
        );
        ensure!(
            message_bytes / ML_KEM_BRAID_CHUNK_BYTES <= MAX_SOURCE_CHUNKS,
            "ML-KEM Braid decoder exceeds the resource limit"
        );
        Ok(Self {
            message_bytes,
            chunks: BTreeMap::new(),
            decoded: None,
        })
    }

    fn add_chunk(&mut self, chunk: &MlKemBraidChunk) -> Result<()> {
        ensure!(
            self.decoded.is_none(),
            "ML-KEM Braid decoder received data after completion"
        );
        ensure!(
            !self.chunks.contains_key(&chunk.point),
            "ML-KEM Braid duplicate or conflicting erasure chunk"
        );
        ensure!(
            self.chunks.len() < self.source_count(),
            "ML-KEM Braid decoder resource limit exceeded"
        );
        self.chunks.insert(chunk.point, chunk.bytes.to_vec());
        if self.chunks.len() == self.source_count() {
            self.decoded = Some(self.decode()?);
        }
        Ok(())
    }

    fn has_message(&self) -> bool {
        self.decoded.is_some()
    }

    fn take_message(&mut self) -> Result<Vec<u8>> {
        self.decoded
            .take()
            .ok_or_else(|| anyhow!("ML-KEM Braid message is incomplete"))
    }

    fn source_count(&self) -> usize {
        self.message_bytes / ML_KEM_BRAID_CHUNK_BYTES
    }

    fn validate_active(&self, expected_bytes: usize) -> Result<()> {
        self.validate()?;
        ensure!(
            self.message_bytes == expected_bytes
                && self.decoded.is_none()
                && self.chunks.len() < self.source_count(),
            "persisted ML-KEM Braid active decoder state is invalid"
        );
        Ok(())
    }

    fn decode(&self) -> Result<Vec<u8>> {
        let count = self.source_count();
        if (0..count).all(|point| self.chunks.contains_key(&(point as u16))) {
            let mut message = Vec::with_capacity(self.message_bytes);
            for point in 0..count {
                message.extend_from_slice(
                    self.chunks
                        .get(&(point as u16))
                        .ok_or_else(|| anyhow!("ML-KEM Braid systematic chunk is missing"))?,
                );
            }
            return Ok(message);
        }

        let points = self.chunks.keys().copied().collect::<Vec<_>>();
        let codewords = self.chunks.values().cloned().collect::<Vec<_>>();
        let mut denominators = Vec::with_capacity(count);
        for (index, point) in points.iter().enumerate() {
            let mut denominator = 1u16;
            for (other_index, other) in points.iter().enumerate() {
                if index != other_index {
                    denominator = gf_mul(denominator, point ^ other);
                }
            }
            denominators.push(denominator);
        }
        let weights = batch_inverse(&denominators)?;
        let mut message = Vec::with_capacity(self.message_bytes);
        // Coefficients are cached per target and reused for all 16 symbols.
        // The bounded decoder is O(N^2 * symbols) and stores at most 48 chunks.
        for target in 0..count {
            if let Some(existing) = points.iter().position(|point| *point == target as u16) {
                message.extend_from_slice(&codewords[existing]);
                continue;
            }
            let differences = points
                .iter()
                .map(|point| target as u16 ^ point)
                .collect::<Vec<_>>();
            let inverse_differences = batch_inverse(&differences)?;
            let all_differences = differences.iter().copied().fold(1u16, gf_mul);
            let coefficients = weights
                .iter()
                .zip(inverse_differences)
                .map(|(weight, inverse)| gf_mul(gf_mul(*weight, all_differences), inverse))
                .collect::<Vec<_>>();
            message.extend_from_slice(&combine_codewords(&codewords, &coefficients));
        }
        Ok(message)
    }

    fn validate(&self) -> Result<()> {
        ensure!(
            self.message_bytes != 0
                && self.message_bytes.is_multiple_of(ML_KEM_BRAID_CHUNK_BYTES)
                && self.source_count() <= MAX_SOURCE_CHUNKS,
            "persisted ML-KEM Braid decoder size is invalid"
        );
        ensure!(
            self.chunks.len() <= self.source_count()
                && self
                    .chunks
                    .values()
                    .all(|chunk| chunk.len() == ML_KEM_BRAID_CHUNK_BYTES),
            "persisted ML-KEM Braid decoder chunks are invalid"
        );
        if let Some(decoded) = &self.decoded {
            ensure!(
                decoded.len() == self.message_bytes && self.chunks.len() == self.source_count(),
                "persisted ML-KEM Braid decoded message is invalid"
            );
        }
        Ok(())
    }
}

fn combine_codewords(
    codewords: &[Vec<u8>],
    coefficients: &[u16],
) -> [u8; ML_KEM_BRAID_CHUNK_BYTES] {
    let mut output = [0u8; ML_KEM_BRAID_CHUNK_BYTES];
    for symbol in 0..(ML_KEM_BRAID_CHUNK_BYTES / 2) {
        let mut value = 0u16;
        for (codeword, coefficient) in codewords.iter().zip(coefficients) {
            let source = u16::from_be_bytes([codeword[symbol * 2], codeword[symbol * 2 + 1]]);
            value ^= gf_mul(source, *coefficient);
        }
        output[symbol * 2..symbol * 2 + 2].copy_from_slice(&value.to_be_bytes());
    }
    output
}

fn gf_mul(left: u16, right: u16) -> u16 {
    let mut left = u32::from(left);
    let mut right = right;
    let mut product = 0u32;
    for _ in 0..16 {
        if right & 1 != 0 {
            product ^= left;
        }
        right >>= 1;
        let carry = left & 0x8000;
        left = (left << 1) & 0xffff;
        if carry != 0 {
            left ^= GF_REDUCTION_POLYNOMIAL;
        }
    }
    product as u16
}

fn gf_inverse(value: u16) -> Result<u16> {
    ensure!(value != 0, "ML-KEM Braid field inverse of zero");
    let mut exponent = 65_534u32;
    let mut base = value;
    let mut result = 1u16;
    while exponent != 0 {
        if exponent & 1 != 0 {
            result = gf_mul(result, base);
        }
        base = gf_mul(base, base);
        exponent >>= 1;
    }
    Ok(result)
}

fn batch_inverse(values: &[u16]) -> Result<Vec<u16>> {
    if values.is_empty() {
        return Ok(Vec::new());
    }
    ensure!(
        values.iter().all(|value| *value != 0),
        "ML-KEM Braid field denominator is zero"
    );
    let mut prefixes = Vec::with_capacity(values.len() + 1);
    prefixes.push(1u16);
    for value in values {
        prefixes.push(gf_mul(*prefixes.last().unwrap_or(&1), *value));
    }
    let mut inverse_product = gf_inverse(*prefixes.last().unwrap_or(&1))?;
    let mut output = vec![0u16; values.len()];
    for index in (0..values.len()).rev() {
        output[index] = gf_mul(inverse_product, prefixes[index]);
        inverse_product = gf_mul(inverse_product, values[index]);
    }
    Ok(output)
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase", deny_unknown_fields)]
enum ProtocolState {
    KeysUnsampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
    },
    KeysSampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ek_vector: Vec<u8>,
        header_encoder: ErasureEncoder,
    },
    HeaderSent {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ct1_decoder: ErasureDecoder,
        ek_encoder: ErasureEncoder,
    },
    Ct1Received {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ct1: Vec<u8>,
        ek_encoder: ErasureEncoder,
    },
    EkSentCt1Received {
        epoch: u64,
        auth: RatchetedAuthenticator,
        key_seed: SecretBytes,
        ct1: Vec<u8>,
        ct2_decoder: ErasureDecoder,
    },
    NoHeaderReceived {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header_decoder: ErasureDecoder,
    },
    HeaderReceived {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header: Vec<u8>,
        ek_decoder: ErasureDecoder,
    },
    Ct1Sampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header: Vec<u8>,
        encaps_state: SecretBytes,
        ct1: Vec<u8>,
        ct1_encoder: ErasureEncoder,
        ek_decoder: ErasureDecoder,
    },
    EkReceivedCt1Sampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        encaps_state: SecretBytes,
        ct1: Vec<u8>,
        ek_vector: Vec<u8>,
        ct1_encoder: ErasureEncoder,
    },
    Ct1Acknowledged {
        epoch: u64,
        auth: RatchetedAuthenticator,
        header: Vec<u8>,
        encaps_state: SecretBytes,
        ct1: Vec<u8>,
        ek_decoder: ErasureDecoder,
    },
    Ct2Sampled {
        epoch: u64,
        auth: RatchetedAuthenticator,
        ct2_encoder: ErasureEncoder,
    },
    Poisoned {
        epoch: u64,
    },
}

impl ProtocolState {
    fn epoch(&self) -> u64 {
        match self {
            Self::KeysUnsampled { epoch, .. }
            | Self::KeysSampled { epoch, .. }
            | Self::HeaderSent { epoch, .. }
            | Self::Ct1Received { epoch, .. }
            | Self::EkSentCt1Received { epoch, .. }
            | Self::NoHeaderReceived { epoch, .. }
            | Self::HeaderReceived { epoch, .. }
            | Self::Ct1Sampled { epoch, .. }
            | Self::EkReceivedCt1Sampled { epoch, .. }
            | Self::Ct1Acknowledged { epoch, .. }
            | Self::Ct2Sampled { epoch, .. }
            | Self::Poisoned { epoch } => *epoch,
        }
    }

    #[cfg(test)]
    fn name(&self) -> MlKemBraidStateName {
        match self {
            Self::KeysUnsampled { .. } => MlKemBraidStateName::KeysUnsampled,
            Self::KeysSampled { .. } => MlKemBraidStateName::KeysSampled,
            Self::HeaderSent { .. } => MlKemBraidStateName::HeaderSent,
            Self::Ct1Received { .. } => MlKemBraidStateName::Ct1Received,
            Self::EkSentCt1Received { .. } => MlKemBraidStateName::EkSentCt1Received,
            Self::NoHeaderReceived { .. } => MlKemBraidStateName::NoHeaderReceived,
            Self::HeaderReceived { .. } => MlKemBraidStateName::HeaderReceived,
            Self::Ct1Sampled { .. } => MlKemBraidStateName::Ct1Sampled,
            Self::EkReceivedCt1Sampled { .. } => MlKemBraidStateName::EkReceivedCt1Sampled,
            Self::Ct1Acknowledged { .. } => MlKemBraidStateName::Ct1Acknowledged,
            Self::Ct2Sampled { .. } => MlKemBraidStateName::Ct2Sampled,
            Self::Poisoned { .. } => MlKemBraidStateName::Poisoned,
        }
    }
}

/// Persistable client-only ML-KEM Braid session. The persisted bytes contain
/// plaintext secret state and belong exclusively in the platform secret store.
pub(crate) struct MlKemBraidSession {
    state: ProtocolState,
}

#[derive(Serialize)]
#[serde(deny_unknown_fields)]
struct PersistedSessionRef<'a> {
    revision: u8,
    state: &'a ProtocolState,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedSession {
    revision: u8,
    state: ProtocolState,
}

impl MlKemBraidSession {
    pub fn new_initiator(shared_secret: &[u8; 32]) -> Result<Self> {
        Ok(Self {
            state: ProtocolState::KeysUnsampled {
                epoch: INITIAL_EPOCH,
                auth: RatchetedAuthenticator::initialize(INITIAL_EPOCH, shared_secret)?,
            },
        })
    }

    pub fn new_responder(shared_secret: &[u8; 32]) -> Result<Self> {
        Ok(Self {
            state: ProtocolState::NoHeaderReceived {
                epoch: INITIAL_EPOCH,
                auth: RatchetedAuthenticator::initialize(INITIAL_EPOCH, shared_secret)?,
                header_decoder: ErasureDecoder::new(
                    ML_KEM_BRAID_HEADER_BYTES + ML_KEM_BRAID_MAC_BYTES,
                )?,
            },
        })
    }

    #[cfg(test)]
    pub fn state_name(&self) -> MlKemBraidStateName {
        self.state.name()
    }

    pub fn epoch(&self) -> u64 {
        self.state.epoch()
    }

    pub fn is_poisoned(&self) -> bool {
        matches!(self.state, ProtocolState::Poisoned { .. })
    }

    pub fn destroy(&mut self) {
        let epoch = self.state.epoch();
        self.state = ProtocolState::Poisoned { epoch };
    }

    pub fn try_clone(&self) -> Self {
        Self {
            state: self.state.clone(),
        }
    }

    pub fn send(&mut self) -> Result<MlKemBraidSend> {
        self.send_with_rng(&mut OsRng)
    }

    pub fn send_with_rng<R>(&mut self, rng: &mut R) -> Result<MlKemBraidSend>
    where
        R: RngCore + CryptoRng,
    {
        let epoch = self.state.epoch();
        ensure!(
            !matches!(self.state, ProtocolState::Poisoned { .. }),
            "ML-KEM Braid session is poisoned"
        );
        let state = mem::replace(&mut self.state, ProtocolState::Poisoned { epoch });
        match send_state(state, rng) {
            Ok((state, output)) => {
                self.state = state;
                Ok(output)
            }
            Err(error) => Err(error),
        }
    }

    pub fn receive(&mut self, message: &MlKemBraidMessage) -> Result<MlKemBraidReceive> {
        let epoch = self.state.epoch();
        if let Err(error) = message.validate() {
            self.state = ProtocolState::Poisoned { epoch };
            return Err(error);
        }
        ensure!(
            !matches!(self.state, ProtocolState::Poisoned { .. }),
            "ML-KEM Braid session is poisoned"
        );
        let state = mem::replace(&mut self.state, ProtocolState::Poisoned { epoch });
        match receive_state(state, message) {
            Ok((state, output)) => {
                self.state = state;
                Ok(output)
            }
            Err(error) => Err(error),
        }
    }

    pub fn persist(&self) -> Result<Zeroizing<Vec<u8>>> {
        let encoded = serde_json::to_vec(&PersistedSessionRef {
            revision: PERSISTENCE_REVISION,
            state: &self.state,
        })
        .map_err(|_| anyhow!("ML-KEM Braid state serialization failed"))?;
        Ok(Zeroizing::new(encoded))
    }

    pub fn restore(encoded: &[u8]) -> Result<Self> {
        ensure!(
            encoded.len() <= MAX_PERSISTED_SESSION_BYTES,
            "ML-KEM Braid persisted state exceeds the resource limit"
        );
        let mut persisted: PersistedSession =
            serde_json::from_slice(encoded).context("ML-KEM Braid persisted state is invalid")?;
        ensure!(
            persisted.revision == PERSISTENCE_REVISION,
            "ML-KEM Braid persisted state revision is unsupported"
        );
        validate_restored_state(&mut persisted.state)?;
        Ok(Self {
            state: persisted.state,
        })
    }
}

fn send_state<R>(state: ProtocolState, rng: &mut R) -> Result<(ProtocolState, MlKemBraidSend)>
where
    R: RngCore + CryptoRng,
{
    match state {
        ProtocolState::KeysUnsampled { epoch, auth } => {
            let mut key_seed = Zeroizing::new([0u8; KEY_GENERATION_SEED_SIZE]);
            rng.fill_bytes(key_seed.as_mut());
            let mut key_pair = Zeroizing::new([0u8; incremental::COMPRESSED_KEYPAIR_LEN]);
            incremental::generate_key_pair_compressed(*key_seed, &mut *key_pair);
            let ek_offset = incremental::pk2_len();
            let header_offset = ek_offset * 2;
            let header =
                key_pair[header_offset..header_offset + ML_KEM_BRAID_HEADER_BYTES].to_vec();
            let ek_vector = key_pair[ek_offset..ek_offset + ML_KEM_BRAID_EK_BYTES].to_vec();
            incremental::validate_pk_bytes(&header, &ek_vector)
                .map_err(|_| anyhow!("ML-KEM Braid generated key is invalid"))?;
            let mac = auth.mac_header(epoch, &header)?;
            let mut header_with_mac = header;
            header_with_mac.extend_from_slice(&mac);
            let mut header_encoder = ErasureEncoder::new(&header_with_mac)?;
            let chunk = header_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::Hdr, chunk),
                epoch,
                None,
            )?;
            // Transition (1).
            Ok((
                ProtocolState::KeysSampled {
                    epoch,
                    auth,
                    key_seed: SecretBytes::new(key_seed.to_vec()),
                    ek_vector,
                    header_encoder,
                },
                output,
            ))
        }
        ProtocolState::KeysSampled {
            epoch,
            auth,
            key_seed,
            ek_vector,
            mut header_encoder,
        } => {
            let chunk = header_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::Hdr, chunk),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::KeysSampled {
                    epoch,
                    auth,
                    key_seed,
                    ek_vector,
                    header_encoder,
                },
                output,
            ))
        }
        ProtocolState::HeaderSent {
            epoch,
            auth,
            key_seed,
            ct1_decoder,
            mut ek_encoder,
        } => {
            let chunk = ek_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::Ek, chunk),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::HeaderSent {
                    epoch,
                    auth,
                    key_seed,
                    ct1_decoder,
                    ek_encoder,
                },
                output,
            ))
        }
        ProtocolState::Ct1Received {
            epoch,
            auth,
            key_seed,
            ct1,
            mut ek_encoder,
        } => {
            let chunk = ek_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::EkCt1Ack, chunk),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::Ct1Received {
                    epoch,
                    auth,
                    key_seed,
                    ct1,
                    ek_encoder,
                },
                output,
            ))
        }
        ProtocolState::EkSentCt1Received {
            epoch,
            auth,
            key_seed,
            ct1,
            ct2_decoder,
        } => {
            let output = send_output(
                MlKemBraidMessage::empty(epoch, MlKemBraidMessageType::None),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::EkSentCt1Received {
                    epoch,
                    auth,
                    key_seed,
                    ct1,
                    ct2_decoder,
                },
                output,
            ))
        }
        ProtocolState::NoHeaderReceived {
            epoch,
            auth,
            header_decoder,
        } => {
            let output = send_output(
                MlKemBraidMessage::empty(epoch, MlKemBraidMessageType::None),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::NoHeaderReceived {
                    epoch,
                    auth,
                    header_decoder,
                },
                output,
            ))
        }
        ProtocolState::HeaderReceived {
            epoch,
            mut auth,
            header,
            ek_decoder,
        } => {
            let mut randomness = [0u8; 32];
            rng.fill_bytes(&mut randomness);
            let mut encaps_state = Zeroizing::new(vec![0u8; incremental::encaps_state_len()]);
            let mut raw_shared_secret = Zeroizing::new([0u8; 32]);
            let ciphertext1 = incremental::encapsulate1(
                &header,
                randomness,
                encaps_state.as_mut_slice(),
                raw_shared_secret.as_mut(),
            )
            .map_err(|_| anyhow!("ML-KEM Braid Encaps1 failed"))?;
            randomness.zeroize();
            let output_key = derive_output_key(&raw_shared_secret[..], epoch)?;
            auth.update(epoch, output_key.key())?;
            let ct1 = ciphertext1.value.to_vec();
            let mut ct1_encoder = ErasureEncoder::new(&ct1)?;
            let chunk = ct1_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::Ct1, chunk),
                epoch,
                Some(output_key),
            )?;
            // Transition (7).
            Ok((
                ProtocolState::Ct1Sampled {
                    epoch,
                    auth,
                    header,
                    encaps_state: SecretBytes::new(encaps_state.to_vec()),
                    ct1,
                    ct1_encoder,
                    ek_decoder,
                },
                output,
            ))
        }
        ProtocolState::Ct1Sampled {
            epoch,
            auth,
            header,
            encaps_state,
            ct1,
            mut ct1_encoder,
            ek_decoder,
        } => {
            let chunk = ct1_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::Ct1, chunk),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::Ct1Sampled {
                    epoch,
                    auth,
                    header,
                    encaps_state,
                    ct1,
                    ct1_encoder,
                    ek_decoder,
                },
                output,
            ))
        }
        ProtocolState::EkReceivedCt1Sampled {
            epoch,
            auth,
            encaps_state,
            ct1,
            ek_vector,
            mut ct1_encoder,
        } => {
            let chunk = ct1_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::Ct1, chunk),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::EkReceivedCt1Sampled {
                    epoch,
                    auth,
                    encaps_state,
                    ct1,
                    ek_vector,
                    ct1_encoder,
                },
                output,
            ))
        }
        ProtocolState::Ct1Acknowledged {
            epoch,
            auth,
            header,
            encaps_state,
            ct1,
            ek_decoder,
        } => {
            let output = send_output(
                MlKemBraidMessage::empty(epoch, MlKemBraidMessageType::None),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::Ct1Acknowledged {
                    epoch,
                    auth,
                    header,
                    encaps_state,
                    ct1,
                    ek_decoder,
                },
                output,
            ))
        }
        ProtocolState::Ct2Sampled {
            epoch,
            auth,
            mut ct2_encoder,
        } => {
            let chunk = ct2_encoder.next_chunk()?;
            let output = send_output(
                MlKemBraidMessage::payload(epoch, MlKemBraidMessageType::Ct2, chunk),
                epoch,
                None,
            )?;
            Ok((
                ProtocolState::Ct2Sampled {
                    epoch,
                    auth,
                    ct2_encoder,
                },
                output,
            ))
        }
        ProtocolState::Poisoned { .. } => bail!("ML-KEM Braid session is poisoned"),
    }
}

fn receive_state(
    state: ProtocolState,
    message: &MlKemBraidMessage,
) -> Result<(ProtocolState, MlKemBraidReceive)> {
    match state {
        ProtocolState::KeysUnsampled { epoch, auth } => Ok((
            ProtocolState::KeysUnsampled { epoch, auth },
            receive_output(epoch, None)?,
        )),
        ProtocolState::KeysSampled {
            epoch,
            auth,
            key_seed,
            ek_vector,
            header_encoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::Ct1) {
                let mut ct1_decoder = ErasureDecoder::new(ML_KEM_BRAID_CT1_BYTES)?;
                ct1_decoder.add_chunk(required_data(message)?)?;
                let ek_encoder = ErasureEncoder::new(&ek_vector)?;
                // Transition (2).
                Ok((
                    ProtocolState::HeaderSent {
                        epoch,
                        auth,
                        key_seed,
                        ct1_decoder,
                        ek_encoder,
                    },
                    receive_output(epoch, None)?,
                ))
            } else {
                Ok((
                    ProtocolState::KeysSampled {
                        epoch,
                        auth,
                        key_seed,
                        ek_vector,
                        header_encoder,
                    },
                    receive_output(epoch, None)?,
                ))
            }
        }
        ProtocolState::HeaderSent {
            epoch,
            auth,
            key_seed,
            mut ct1_decoder,
            ek_encoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::Ct1) {
                ct1_decoder.add_chunk(required_data(message)?)?;
                if ct1_decoder.has_message() {
                    let ct1 = ct1_decoder.take_message()?;
                    // Transition (3).
                    return Ok((
                        ProtocolState::Ct1Received {
                            epoch,
                            auth,
                            key_seed,
                            ct1,
                            ek_encoder,
                        },
                        receive_output(epoch, None)?,
                    ));
                }
            }
            Ok((
                ProtocolState::HeaderSent {
                    epoch,
                    auth,
                    key_seed,
                    ct1_decoder,
                    ek_encoder,
                },
                receive_output(epoch, None)?,
            ))
        }
        ProtocolState::Ct1Received {
            epoch,
            auth,
            key_seed,
            ct1,
            ek_encoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::Ct2) {
                let mut ct2_decoder =
                    ErasureDecoder::new(ML_KEM_BRAID_CT2_BYTES + ML_KEM_BRAID_MAC_BYTES)?;
                ct2_decoder.add_chunk(required_data(message)?)?;
                // Transition (4).
                Ok((
                    ProtocolState::EkSentCt1Received {
                        epoch,
                        auth,
                        key_seed,
                        ct1,
                        ct2_decoder,
                    },
                    receive_output(epoch, None)?,
                ))
            } else {
                Ok((
                    ProtocolState::Ct1Received {
                        epoch,
                        auth,
                        key_seed,
                        ct1,
                        ek_encoder,
                    },
                    receive_output(epoch, None)?,
                ))
            }
        }
        ProtocolState::EkSentCt1Received {
            epoch,
            mut auth,
            key_seed,
            ct1,
            mut ct2_decoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::Ct2) {
                ct2_decoder.add_chunk(required_data(message)?)?;
                if ct2_decoder.has_message() {
                    let ct2_with_mac = ct2_decoder.take_message()?;
                    let ct2 = &ct2_with_mac[..ML_KEM_BRAID_CT2_BYTES];
                    let mac = &ct2_with_mac[ML_KEM_BRAID_CT2_BYTES..];
                    let raw_shared_secret = decapsulate(&key_seed, &ct1, ct2)?;
                    let output_key = derive_output_key(&raw_shared_secret[..], epoch)?;
                    auth.update(epoch, output_key.key())?;
                    let mut authenticated =
                        Vec::with_capacity(ML_KEM_BRAID_CT1_BYTES + ML_KEM_BRAID_CT2_BYTES);
                    authenticated.extend_from_slice(&ct1);
                    authenticated.extend_from_slice(ct2);
                    auth.verify_ciphertext(epoch, &authenticated, mac)?;
                    let next_epoch = checked_next_epoch(epoch)?;
                    // Transition (5).
                    return Ok((
                        ProtocolState::NoHeaderReceived {
                            epoch: next_epoch,
                            auth,
                            header_decoder: ErasureDecoder::new(
                                ML_KEM_BRAID_HEADER_BYTES + ML_KEM_BRAID_MAC_BYTES,
                            )?,
                        },
                        MlKemBraidReceive {
                            receiving_epoch: previous_epoch(epoch)?,
                            output_key: Some(output_key),
                        },
                    ));
                }
            }
            Ok((
                ProtocolState::EkSentCt1Received {
                    epoch,
                    auth,
                    key_seed,
                    ct1,
                    ct2_decoder,
                },
                receive_output(epoch, None)?,
            ))
        }
        ProtocolState::NoHeaderReceived {
            epoch,
            auth,
            mut header_decoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::Hdr) {
                header_decoder.add_chunk(required_data(message)?)?;
                if header_decoder.has_message() {
                    let header_with_mac = header_decoder.take_message()?;
                    let header = header_with_mac[..ML_KEM_BRAID_HEADER_BYTES].to_vec();
                    auth.verify_header(
                        epoch,
                        &header,
                        &header_with_mac[ML_KEM_BRAID_HEADER_BYTES..],
                    )?;
                    // Transition (6).
                    return Ok((
                        ProtocolState::HeaderReceived {
                            epoch,
                            auth,
                            header,
                            ek_decoder: ErasureDecoder::new(ML_KEM_BRAID_EK_BYTES)?,
                        },
                        receive_output(epoch, None)?,
                    ));
                }
            }
            Ok((
                ProtocolState::NoHeaderReceived {
                    epoch,
                    auth,
                    header_decoder,
                },
                receive_output(epoch, None)?,
            ))
        }
        ProtocolState::HeaderReceived {
            epoch,
            auth,
            header,
            ek_decoder,
        } => Ok((
            ProtocolState::HeaderReceived {
                epoch,
                auth,
                header,
                ek_decoder,
            },
            receive_output(epoch, None)?,
        )),
        remaining => receive_state_after_header(remaining, message),
    }
}

fn receive_state_after_header(
    state: ProtocolState,
    message: &MlKemBraidMessage,
) -> Result<(ProtocolState, MlKemBraidReceive)> {
    match state {
        ProtocolState::Ct1Sampled {
            epoch,
            auth,
            header,
            encaps_state,
            ct1,
            ct1_encoder,
            mut ek_decoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::Ek) {
                ek_decoder.add_chunk(required_data(message)?)?;
                if ek_decoder.has_message() {
                    let ek_vector = ek_decoder.take_message()?;
                    validate_encapsulation_key(&header, &ek_vector)?;
                    // Transition (10).
                    return Ok((
                        ProtocolState::EkReceivedCt1Sampled {
                            epoch,
                            auth,
                            encaps_state,
                            ct1,
                            ek_vector,
                            ct1_encoder,
                        },
                        receive_output(epoch, None)?,
                    ));
                }
            } else if is_payload(message, epoch, MlKemBraidMessageType::EkCt1Ack) {
                ek_decoder.add_chunk(required_data(message)?)?;
                if ek_decoder.has_message() {
                    let ek_vector = ek_decoder.take_message()?;
                    validate_encapsulation_key(&header, &ek_vector)?;
                    let ct2_encoder =
                        complete_encapsulation(&auth, epoch, &encaps_state, &ct1, &ek_vector)?;
                    // Transition (9).
                    return Ok((
                        ProtocolState::Ct2Sampled {
                            epoch,
                            auth,
                            ct2_encoder,
                        },
                        receive_output(epoch, None)?,
                    ));
                }
                // Transition (8).
                return Ok((
                    ProtocolState::Ct1Acknowledged {
                        epoch,
                        auth,
                        header,
                        encaps_state,
                        ct1,
                        ek_decoder,
                    },
                    receive_output(epoch, None)?,
                ));
            }
            Ok((
                ProtocolState::Ct1Sampled {
                    epoch,
                    auth,
                    header,
                    encaps_state,
                    ct1,
                    ct1_encoder,
                    ek_decoder,
                },
                receive_output(epoch, None)?,
            ))
        }
        ProtocolState::EkReceivedCt1Sampled {
            epoch,
            auth,
            encaps_state,
            ct1,
            ek_vector,
            ct1_encoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::EkCt1Ack) {
                let ct2_encoder =
                    complete_encapsulation(&auth, epoch, &encaps_state, &ct1, &ek_vector)?;
                // Transition (12).
                Ok((
                    ProtocolState::Ct2Sampled {
                        epoch,
                        auth,
                        ct2_encoder,
                    },
                    receive_output(epoch, None)?,
                ))
            } else {
                Ok((
                    ProtocolState::EkReceivedCt1Sampled {
                        epoch,
                        auth,
                        encaps_state,
                        ct1,
                        ek_vector,
                        ct1_encoder,
                    },
                    receive_output(epoch, None)?,
                ))
            }
        }
        ProtocolState::Ct1Acknowledged {
            epoch,
            auth,
            header,
            encaps_state,
            ct1,
            mut ek_decoder,
        } => {
            if is_payload(message, epoch, MlKemBraidMessageType::EkCt1Ack) {
                ek_decoder.add_chunk(required_data(message)?)?;
                if ek_decoder.has_message() {
                    let ek_vector = ek_decoder.take_message()?;
                    validate_encapsulation_key(&header, &ek_vector)?;
                    let ct2_encoder =
                        complete_encapsulation(&auth, epoch, &encaps_state, &ct1, &ek_vector)?;
                    // Transition (11).
                    return Ok((
                        ProtocolState::Ct2Sampled {
                            epoch,
                            auth,
                            ct2_encoder,
                        },
                        receive_output(epoch, None)?,
                    ));
                }
            }
            Ok((
                ProtocolState::Ct1Acknowledged {
                    epoch,
                    auth,
                    header,
                    encaps_state,
                    ct1,
                    ek_decoder,
                },
                receive_output(epoch, None)?,
            ))
        }
        ProtocolState::Ct2Sampled {
            epoch,
            auth,
            ct2_encoder,
        } => {
            let next_epoch = checked_next_epoch(epoch)?;
            if message.epoch == next_epoch {
                // Transition (13).
                Ok((
                    ProtocolState::KeysUnsampled {
                        epoch: next_epoch,
                        auth,
                    },
                    MlKemBraidReceive {
                        receiving_epoch: epoch,
                        output_key: None,
                    },
                ))
            } else {
                Ok((
                    ProtocolState::Ct2Sampled {
                        epoch,
                        auth,
                        ct2_encoder,
                    },
                    receive_output(epoch, None)?,
                ))
            }
        }
        ProtocolState::Poisoned { .. } => bail!("ML-KEM Braid session is poisoned"),
        _ => bail!("ML-KEM Braid internal state dispatch failed"),
    }
}

fn send_output(
    message: MlKemBraidMessage,
    state_epoch: u64,
    output_key: Option<MlKemBraidOutputKey>,
) -> Result<MlKemBraidSend> {
    Ok(MlKemBraidSend {
        message,
        sending_epoch: previous_epoch(state_epoch)?,
        output_key,
    })
}

fn receive_output(
    state_epoch: u64,
    output_key: Option<MlKemBraidOutputKey>,
) -> Result<MlKemBraidReceive> {
    Ok(MlKemBraidReceive {
        receiving_epoch: previous_epoch(state_epoch)?,
        output_key,
    })
}

fn previous_epoch(epoch: u64) -> Result<u64> {
    epoch
        .checked_sub(1)
        .ok_or_else(|| anyhow!("ML-KEM Braid epoch underflow"))
}

fn checked_next_epoch(epoch: u64) -> Result<u64> {
    epoch
        .checked_add(1)
        .ok_or_else(|| anyhow!("ML-KEM Braid epoch exhausted"))
}

fn is_payload(
    message: &MlKemBraidMessage,
    epoch: u64,
    message_type: MlKemBraidMessageType,
) -> bool {
    message.epoch == epoch && message.message_type == message_type
}

fn required_data(message: &MlKemBraidMessage) -> Result<&MlKemBraidChunk> {
    message
        .data
        .as_ref()
        .ok_or_else(|| anyhow!("ML-KEM Braid message data is missing"))
}

fn derive_output_key(raw_shared_secret: &[u8], epoch: u64) -> Result<MlKemBraidOutputKey> {
    let mut info = Vec::with_capacity(PROTOCOL_INFO.len() + OUTPUT_KEY_LABEL.len() + 8);
    info.extend_from_slice(PROTOCOL_INFO);
    info.extend_from_slice(OUTPUT_KEY_LABEL);
    info.extend_from_slice(&epoch.to_be_bytes());
    let mut output = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(Some(&[0u8; 32]), raw_shared_secret)
        .expand(&info, output.as_mut())
        .map_err(|_| anyhow!("ML-KEM Braid output-key KDF failed"))?;
    Ok(MlKemBraidOutputKey { epoch, key: output })
}

fn validate_encapsulation_key(header: &[u8], ek_vector: &[u8]) -> Result<()> {
    ensure!(
        header.len() == ML_KEM_BRAID_HEADER_BYTES && ek_vector.len() == ML_KEM_BRAID_EK_BYTES,
        "ML-KEM Braid encapsulation key length is invalid"
    );
    incremental::validate_pk_bytes(header, ek_vector)
        .map_err(|_| anyhow!("ML-KEM Braid encapsulation key integrity failed"))
}

fn complete_encapsulation(
    auth: &RatchetedAuthenticator,
    epoch: u64,
    encaps_state: &SecretBytes,
    ct1: &[u8],
    ek_vector: &[u8],
) -> Result<ErasureEncoder> {
    encaps_state.ensure_len(incremental::encaps_state_len())?;
    ensure!(
        ct1.len() == ML_KEM_BRAID_CT1_BYTES && ek_vector.len() == ML_KEM_BRAID_EK_BYTES,
        "ML-KEM Braid encapsulation input length is invalid"
    );
    let state: &[u8; incremental::encaps_state_len()] = encaps_state
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("ML-KEM Braid encapsulation state is invalid"))?;
    let public_key: &[u8; incremental::pk2_len()] = ek_vector
        .try_into()
        .map_err(|_| anyhow!("ML-KEM Braid encapsulation key vector is invalid"))?;
    let ciphertext2 = incremental::encapsulate2(state, public_key);
    let mut authenticated = Vec::with_capacity(ML_KEM_BRAID_CT1_BYTES + ML_KEM_BRAID_CT2_BYTES);
    authenticated.extend_from_slice(ct1);
    authenticated.extend_from_slice(&ciphertext2.value);
    let mac = auth.mac_ciphertext(epoch, &authenticated)?;
    let mut encoded = ciphertext2.value.to_vec();
    encoded.extend_from_slice(&mac);
    ErasureEncoder::new(&encoded)
}

fn decapsulate(key_seed: &SecretBytes, ct1: &[u8], ct2: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    key_seed.ensure_len(KEY_GENERATION_SEED_SIZE)?;
    ensure!(
        ct1.len() == ML_KEM_BRAID_CT1_BYTES && ct2.len() == ML_KEM_BRAID_CT2_BYTES,
        "ML-KEM Braid ciphertext length is invalid"
    );
    let mut seed = Zeroizing::new([0u8; KEY_GENERATION_SEED_SIZE]);
    seed.copy_from_slice(key_seed.as_slice());
    let mut key_pair = Zeroizing::new([0u8; incremental::COMPRESSED_KEYPAIR_LEN]);
    incremental::generate_key_pair_compressed(*seed, &mut *key_pair);
    let ciphertext1 = Ciphertext1 {
        value: ct1
            .try_into()
            .map_err(|_| anyhow!("ML-KEM Braid ct1 is invalid"))?,
    };
    let ciphertext2 = Ciphertext2 {
        value: ct2
            .try_into()
            .map_err(|_| anyhow!("ML-KEM Braid ct2 is invalid"))?,
    };
    let mut shared_secret =
        incremental::decapsulate_compressed_key(&key_pair, &ciphertext1, &ciphertext2);
    let mut output = [0u8; 32];
    output.copy_from_slice(shared_secret.as_slice());
    shared_secret.zeroize();
    Ok(Zeroizing::new(output))
}

fn validate_encoder(encoder: &mut ErasureEncoder, expected_bytes: usize) -> Result<()> {
    encoder.rebuild_cache()?;
    ensure!(
        encoder.message_bytes() == expected_bytes,
        "persisted ML-KEM Braid encoder size is invalid"
    );
    Ok(())
}

fn validate_restored_state(state: &mut ProtocolState) -> Result<()> {
    ensure!(
        state.epoch() != 0,
        "persisted ML-KEM Braid epoch is invalid"
    );
    match state {
        ProtocolState::KeysUnsampled { auth, .. } => auth.validate(),
        ProtocolState::KeysSampled {
            auth,
            key_seed,
            ek_vector,
            header_encoder,
            ..
        } => {
            auth.validate()?;
            key_seed.ensure_len(KEY_GENERATION_SEED_SIZE)?;
            ensure!(
                ek_vector.len() == ML_KEM_BRAID_EK_BYTES,
                "persisted ML-KEM Braid ek length is invalid"
            );
            validate_encoder(
                header_encoder,
                ML_KEM_BRAID_HEADER_BYTES + ML_KEM_BRAID_MAC_BYTES,
            )
        }
        ProtocolState::HeaderSent {
            auth,
            key_seed,
            ct1_decoder,
            ek_encoder,
            ..
        } => {
            auth.validate()?;
            key_seed.ensure_len(KEY_GENERATION_SEED_SIZE)?;
            ct1_decoder.validate_active(ML_KEM_BRAID_CT1_BYTES)?;
            validate_encoder(ek_encoder, ML_KEM_BRAID_EK_BYTES)
        }
        ProtocolState::Ct1Received {
            auth,
            key_seed,
            ct1,
            ek_encoder,
            ..
        } => {
            auth.validate()?;
            key_seed.ensure_len(KEY_GENERATION_SEED_SIZE)?;
            ensure!(
                ct1.len() == ML_KEM_BRAID_CT1_BYTES,
                "persisted ML-KEM Braid ct1 length is invalid"
            );
            validate_encoder(ek_encoder, ML_KEM_BRAID_EK_BYTES)
        }
        ProtocolState::EkSentCt1Received {
            auth,
            key_seed,
            ct1,
            ct2_decoder,
            ..
        } => {
            auth.validate()?;
            key_seed.ensure_len(KEY_GENERATION_SEED_SIZE)?;
            ensure!(
                ct1.len() == ML_KEM_BRAID_CT1_BYTES,
                "persisted ML-KEM Braid ct1 length is invalid"
            );
            ct2_decoder.validate_active(ML_KEM_BRAID_CT2_BYTES + ML_KEM_BRAID_MAC_BYTES)
        }
        ProtocolState::NoHeaderReceived {
            auth,
            header_decoder,
            ..
        } => {
            auth.validate()?;
            header_decoder.validate_active(ML_KEM_BRAID_HEADER_BYTES + ML_KEM_BRAID_MAC_BYTES)
        }
        ProtocolState::HeaderReceived {
            auth,
            header,
            ek_decoder,
            ..
        } => {
            auth.validate()?;
            ensure!(
                header.len() == ML_KEM_BRAID_HEADER_BYTES,
                "persisted ML-KEM Braid header length is invalid"
            );
            ek_decoder.validate_active(ML_KEM_BRAID_EK_BYTES)
        }
        ProtocolState::Ct1Sampled {
            auth,
            header,
            encaps_state,
            ct1,
            ct1_encoder,
            ek_decoder,
            ..
        } => {
            auth.validate()?;
            ensure!(
                header.len() == ML_KEM_BRAID_HEADER_BYTES && ct1.len() == ML_KEM_BRAID_CT1_BYTES,
                "persisted ML-KEM Braid sampled state length is invalid"
            );
            encaps_state.ensure_len(incremental::encaps_state_len())?;
            validate_encoder(ct1_encoder, ML_KEM_BRAID_CT1_BYTES)?;
            ek_decoder.validate_active(ML_KEM_BRAID_EK_BYTES)
        }
        ProtocolState::EkReceivedCt1Sampled {
            auth,
            encaps_state,
            ct1,
            ek_vector,
            ct1_encoder,
            ..
        } => {
            auth.validate()?;
            encaps_state.ensure_len(incremental::encaps_state_len())?;
            ensure!(
                ct1.len() == ML_KEM_BRAID_CT1_BYTES && ek_vector.len() == ML_KEM_BRAID_EK_BYTES,
                "persisted ML-KEM Braid sampled state length is invalid"
            );
            validate_encoder(ct1_encoder, ML_KEM_BRAID_CT1_BYTES)
        }
        ProtocolState::Ct1Acknowledged {
            auth,
            header,
            encaps_state,
            ct1,
            ek_decoder,
            ..
        } => {
            auth.validate()?;
            encaps_state.ensure_len(incremental::encaps_state_len())?;
            ensure!(
                header.len() == ML_KEM_BRAID_HEADER_BYTES && ct1.len() == ML_KEM_BRAID_CT1_BYTES,
                "persisted ML-KEM Braid acknowledged state length is invalid"
            );
            ek_decoder.validate_active(ML_KEM_BRAID_EK_BYTES)
        }
        ProtocolState::Ct2Sampled {
            auth, ct2_encoder, ..
        } => {
            auth.validate()?;
            validate_encoder(ct2_encoder, ML_KEM_BRAID_CT2_BYTES + ML_KEM_BRAID_MAC_BYTES)
        }
        ProtocolState::Poisoned { .. } => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rand::{SeedableRng, rngs::StdRng};

    const TEST_SECRET: [u8; 32] = [0x5a; 32];

    #[test]
    fn authenticator_known_answer() {
        let auth = RatchetedAuthenticator::initialize(1, &TEST_SECRET).unwrap();
        assert_eq!(
            hex(auth.root_key.as_slice()),
            "aec27dcc35663c5a72873280df06f0195496867754eb460b76b5a7c1b85b3955"
        );
        assert_eq!(
            hex(auth.mac_key.as_slice()),
            "b2d0246c8831cc34828fa15e0907e564c6781fc2718f649ea684cf013487a2a5"
        );
        let header = (0u8..64).collect::<Vec<_>>();
        assert_eq!(
            hex(&auth.mac_header(1, &header).unwrap()),
            "bb34450be173a859b7e0ac08124b60fb091d5f59ffd666fde8f8be1a4b1fb92c"
        );
    }

    #[test]
    fn reed_solomon_known_answer_and_any_n_recovery() {
        let mut message = vec![0u8; 64];
        for symbol in message[..32].chunks_exact_mut(2) {
            symbol.copy_from_slice(&1u16.to_be_bytes());
        }
        for symbol in message[32..].chunks_exact_mut(2) {
            symbol.copy_from_slice(&2u16.to_be_bytes());
        }
        let mut encoder = ErasureEncoder::new(&message).unwrap();
        let first = encoder.next_chunk().unwrap();
        let _second = encoder.next_chunk().unwrap();
        let parity = encoder.next_chunk().unwrap();
        assert_eq!(first.point(), 0);
        assert!(
            parity
                .bytes()
                .chunks_exact(2)
                .all(|symbol| symbol == 7u16.to_be_bytes())
        );

        let mut decoder = ErasureDecoder::new(64).unwrap();
        decoder.add_chunk(&parity).unwrap();
        decoder.add_chunk(&first).unwrap();
        assert_eq!(decoder.take_message().unwrap(), message);
    }

    #[test]
    fn strict_wire_message_rejects_unknown_and_invalid_combinations() {
        assert!(
            serde_json::from_str::<MlKemBraidMessage>(
                r#"{"epoch":1,"type":"None","unexpected":true}"#
            )
            .is_err()
        );
        assert!(serde_json::from_str::<MlKemBraidMessage>(r#"{"epoch":1,"type":"Hdr"}"#).is_err());
        assert!(serde_json::from_str::<MlKemBraidMessage>(r#"{"epoch":0,"type":"None"}"#).is_err());
        assert!(
            serde_json::from_str::<MlKemBraidMessage>(
                r#"{"epoch":1,"type":"None","data":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#
            )
            .is_err()
        );
        let oversized_chunk = serde_json::json!({
            "epoch": 1,
            "type": "Hdr",
            "data": "A".repeat(ENCODED_CHUNK_BYTES + 1),
        });
        assert!(serde_json::from_value::<MlKemBraidMessage>(oversized_chunk).is_err());
    }

    #[test]
    fn persisted_state_rejects_oversized_input_before_deserialization() {
        let oversized = vec![b' '; MAX_PERSISTED_SESSION_BYTES + 1];
        assert!(MlKemBraidSession::restore(&oversized).is_err());
    }

    #[test]
    fn duplicate_chunk_poisoning_is_fail_closed() {
        let mut rng = StdRng::seed_from_u64(7);
        let mut alice = MlKemBraidSession::new_initiator(&TEST_SECRET).unwrap();
        let mut bob = MlKemBraidSession::new_responder(&TEST_SECRET).unwrap();
        let sent = alice.send_with_rng(&mut rng).unwrap();
        bob.receive(&sent.message).unwrap();
        assert!(bob.receive(&sent.message).is_err());
        assert!(bob.is_poisoned());
        assert!(bob.send_with_rng(&mut rng).is_err());
    }

    #[test]
    fn header_tamper_poisons_session() {
        let mut rng = StdRng::seed_from_u64(11);
        let mut alice = MlKemBraidSession::new_initiator(&TEST_SECRET).unwrap();
        let mut bob = MlKemBraidSession::new_responder(&TEST_SECRET).unwrap();
        for index in 0..3 {
            let mut sent = alice.send_with_rng(&mut rng).unwrap();
            if index == 1 {
                sent.message.data.as_mut().unwrap().bytes[0] ^= 1;
            }
            let result = bob.receive(&sent.message);
            if index < 2 {
                result.unwrap();
            } else {
                assert!(result.is_err());
            }
        }
        assert!(bob.is_poisoned());
    }

    #[test]
    fn full_rotation_emits_equal_epoch_key_and_restores_state() {
        let mut rng = StdRng::seed_from_u64(23);
        let mut alice = MlKemBraidSession::new_initiator(&TEST_SECRET).unwrap();
        let mut bob = MlKemBraidSession::new_responder(&TEST_SECRET).unwrap();
        let first = alice.send_with_rng(&mut rng).unwrap();
        bob.receive(&first.message).unwrap();
        let persisted = alice.persist().unwrap();
        alice = MlKemBraidSession::restore(&persisted).unwrap();

        let (alice_key, bob_key) = drive_until_epoch_one(&mut alice, &mut bob, &mut rng);
        assert_eq!(alice_key, bob_key);
        assert_eq!(alice.epoch(), 2);
        assert_eq!(bob.epoch(), 2);
        assert_eq!(alice.state_name(), MlKemBraidStateName::NoHeaderReceived);
        assert!(matches!(
            bob.state_name(),
            MlKemBraidStateName::KeysUnsampled | MlKemBraidStateName::KeysSampled
        ));
    }

    #[test]
    fn reordered_and_lost_chunks_still_make_pcs_progress() {
        let mut rng = StdRng::seed_from_u64(31);
        let mut alice = MlKemBraidSession::new_initiator(&TEST_SECRET).unwrap();
        let mut bob = MlKemBraidSession::new_responder(&TEST_SECRET).unwrap();
        let mut a_to_b = Vec::new();
        let mut b_to_a = Vec::new();
        let mut alice_key = None;
        let mut bob_key = None;

        for tick in 0..1_500usize {
            let sent_a = alice.send_with_rng(&mut rng).unwrap();
            record_key(&mut alice_key, sent_a.output_key);
            if tick % 5 != 0 {
                a_to_b.push(sent_a.message);
            }

            let sent_b = bob.send_with_rng(&mut rng).unwrap();
            record_key(&mut bob_key, sent_b.output_key);
            if tick % 7 != 0 {
                b_to_a.push(sent_b.message);
            }

            if tick % 3 != 0 {
                if let Some(message) = a_to_b.pop() {
                    let received = bob.receive(&message).unwrap();
                    record_key(&mut bob_key, received.output_key);
                }
                if let Some(message) = b_to_a.pop() {
                    let received = alice.receive(&message).unwrap();
                    record_key(&mut alice_key, received.output_key);
                }
            }

            if alice_key.is_some() && bob_key.is_some() && alice.epoch() >= 2 && bob.epoch() >= 2 {
                break;
            }
        }
        assert_eq!(alice_key, bob_key);
        assert!(alice_key.is_some());
        assert!(alice.epoch() >= 2 && bob.epoch() >= 2);
    }

    #[test]
    fn epoch_cannot_wrap() {
        assert!(checked_next_epoch(u64::MAX).is_err());
        assert_eq!(previous_epoch(1).unwrap(), 0);
    }

    fn drive_until_epoch_one(
        alice: &mut MlKemBraidSession,
        bob: &mut MlKemBraidSession,
        rng: &mut StdRng,
    ) -> ([u8; 32], [u8; 32]) {
        let mut alice_key = None;
        let mut bob_key = None;
        for _ in 0..512 {
            let sent_a = alice.send_with_rng(rng).unwrap();
            let sending_epoch_a = sent_a.sending_epoch;
            record_key(&mut alice_key, sent_a.output_key);
            let received_b = bob.receive(&sent_a.message).unwrap();
            assert_eq!(received_b.receiving_epoch, sending_epoch_a);
            record_key(&mut bob_key, received_b.output_key);

            let sent_b = bob.send_with_rng(rng).unwrap();
            let sending_epoch_b = sent_b.sending_epoch;
            record_key(&mut bob_key, sent_b.output_key);
            let received_a = alice.receive(&sent_b.message).unwrap();
            assert_eq!(received_a.receiving_epoch, sending_epoch_b);
            record_key(&mut alice_key, received_a.output_key);
            if alice_key.is_some() && bob_key.is_some() && alice.epoch() == 2 && bob.epoch() == 2 {
                break;
            }
        }
        (alice_key.unwrap(), bob_key.unwrap())
    }

    fn record_key(target: &mut Option<[u8; 32]>, candidate: Option<MlKemBraidOutputKey>) {
        if let Some(key) = candidate {
            if key.epoch() == 1 {
                *target = Some(*key.key());
            }
        }
    }

    fn hex(bytes: &[u8]) -> String {
        use std::fmt::Write as _;
        let mut output = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            write!(&mut output, "{byte:02x}").unwrap();
        }
        output
    }
}
