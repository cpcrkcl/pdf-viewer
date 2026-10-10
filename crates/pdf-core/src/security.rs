//! Re-applying password protection to exported working copies.

use std::collections::BTreeMap;
use std::sync::Arc;

use lopdf::encryption::crypt_filters::{Aes128CryptFilter, CryptFilter};
use lopdf::{Document as LoDocument, EncryptionState, EncryptionVersion, Object, Permissions, StringFormat};

use crate::error::{CoreError, CoreResult};
use crate::loader::AccessPermissions;

/// Encrypts `document` in place with AES-128 (standard security handler R4).
pub fn encrypt(
    document: &mut LoDocument,
    user_password: &str,
    owner_password: &str,
    permissions: AccessPermissions,
) -> CoreResult<()> {
    if !document.trailer.has(b"ID") {
        let seed = crate::ids::sha256_hex(uuid::Uuid::new_v4().as_bytes());
        let id = seed.as_bytes()[..16].to_vec();
        document.trailer.set(
            "ID",
            vec![
                Object::String(id.clone(), StringFormat::Hexadecimal),
                Object::String(id, StringFormat::Hexadecimal),
            ],
        );
    }
    let filter: Arc<dyn CryptFilter> = Arc::new(Aes128CryptFilter);
    let crypt_filters = BTreeMap::from([(b"StdCF".to_vec(), filter)]);
    let state = EncryptionState::try_from(EncryptionVersion::V4 {
        document,
        encrypt_metadata: true,
        crypt_filters,
        stream_filter: b"StdCF".to_vec(),
        string_filter: b"StdCF".to_vec(),
        owner_password,
        user_password,
        permissions: Permissions::from_bits_retain(u64::from(permissions.0) | (0xffff_ffff << 32)),
    })
    .map_err(|_| CoreError::ExportWriteFailed)?;
    document.encrypt(&state).map_err(|_| CoreError::ExportWriteFailed)
}
