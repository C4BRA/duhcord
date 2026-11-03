use std::{
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

use keyring::{mock::MockCredential, Error as KeyringError};

use super::*;

#[test]
fn mock_keyring_fail_closed_directory_encryption_and_pairings() {
    keyring::set_default_credential_builder(keyring::mock::default_credential_builder());
    let root = std::env::temp_dir().join(format!(
        "duhcord-store-test-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let store = Store::open(&root).unwrap();

    let account = store.create_account(450001).unwrap();
    assert!(store.create_account(450001).is_err());
    let directory = Directory::default();
    store.save_directory(&account, &directory).unwrap();
    assert!(store.load_account(450001).unwrap().is_some());

    let token = b"temporary pairing token";
    let pairing = store.add_pairing(token, "vencord", 450001).unwrap();
    assert!(store.has_pairing(token, "vencord", 450001).unwrap());
    assert_eq!(store.pairings().unwrap(), vec![pairing.clone()]);
    assert!(!fs::read_to_string(root.join("pairings.json"))
        .unwrap()
        .contains("temporary pairing token"));
    assert!(store.revoke_pairing(&Store::pairing_hash(token)).unwrap());
    assert!(!store.has_pairing(token, "vencord", 450001).unwrap());

    store.with_entry(450002, |_| Ok(())).unwrap();
    let entries = store
        .entries
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let credential = entries["450002"].get_credential();
    let mock = credential.downcast_ref::<MockCredential>().unwrap();
    mock.set_error(KeyringError::Invalid(
        "injected".to_owned(),
        "test error".to_owned(),
    ));
    drop(entries);
    assert!(matches!(
        store.create_account(450002),
        Err(StoreError::Locked(_))
    ));
    assert!(store.load_account(450002).unwrap().is_none());

    let directory_path = root.join("accounts").join("450001.v3.dir");
    let corrupt = b"corrupt encrypted directory";
    fs::write(&directory_path, corrupt).unwrap();
    assert!(matches!(
        store.load_account(450001),
        Err(StoreError::Locked(_))
    ));
    assert_eq!(fs::read(&directory_path).unwrap(), corrupt);

    fs::remove_dir_all(root).unwrap();
}
