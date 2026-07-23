use lico_client_native::core::secure_mesh_secret_store::SecretBytes;

fn clone_forbidden(value: SecretBytes) {
    let _ = value.clone();
}

fn require_default<T: Default>() {}

fn default_forbidden() {
    require_default::<SecretBytes>();
}

trait UncheckedConstructorFallback {
    fn new() -> Self;
}

impl UncheckedConstructorFallback for SecretBytes {
    fn new() -> Self {
        panic!("fallback constructor must never run")
    }
}

fn unchecked_constructor_forbidden() -> SecretBytes {
    SecretBytes::new(Vec::new())
}

fn private_field_forbidden() -> SecretBytes {
    SecretBytes {
        0: Vec::new(),
    }
}

fn require_deref<T: std::ops::Deref<Target = [u8]>>(_value: &T) {}
fn require_as_ref<T: AsRef<[u8]>>(_value: &T) {}
fn require_borrow<T: std::borrow::Borrow<[u8]>>(_value: &T) {}
fn require_display<T: std::fmt::Display>(_value: &T) {}

fn implicit_exposure_forbidden(value: &SecretBytes) {
    require_deref(value);
    require_as_ref(value);
    require_borrow(value);
    require_display(value);
}

fn main() {}
