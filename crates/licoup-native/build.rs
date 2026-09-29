//! Injects `LICO_CLIENT_PRODUCT_VERSION` from the build environment so packaged
//! builds embed the real product version instead of the development fallback.
//! The packaging pipeline sets it from `tools/client-version.json`; a malformed
//! value fails the build rather than shipping a wrong version.

fn main() {
    let source = "resources/state-machines/update-handoff.json";
    println!("cargo:rerun-if-changed={source}");
    let output = std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR"))
        .join("state_machines.rs");
    licoup_state_machine_codegen::compile_file(source, output)
        .expect("compile native client state machines");

    println!("cargo:rerun-if-env-changed=LICO_CLIENT_PRODUCT_VERSION");
    let Ok(value) = std::env::var("LICO_CLIENT_PRODUCT_VERSION") else {
        return;
    };
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return;
    }
    assert!(
        looks_like_semver(trimmed),
        "LICO_CLIENT_PRODUCT_VERSION must be valid semantic versioning"
    );
    println!("cargo:rustc-env=LICO_CLIENT_PRODUCT_VERSION={trimmed}");
}

fn looks_like_semver(value: &str) -> bool {
    let core = value
        .split(|character| matches!(character, '-' | '+'))
        .next()
        .unwrap_or(value);
    let mut parts = core.split('.');
    let mut count = 0_usize;
    while let Some(part) = parts.next() {
        count += 1;
        if count > 3 || part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()) {
            return false;
        }
    }
    count == 3
}
