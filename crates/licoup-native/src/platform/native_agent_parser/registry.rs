use super::adapters::{AdapterContract, contract};
use crate::platform::runtime_adapters::RuntimeAdapter;

pub(in crate::platform) fn parser_for(adapter: RuntimeAdapter) -> AdapterContract {
    contract(adapter)
}
