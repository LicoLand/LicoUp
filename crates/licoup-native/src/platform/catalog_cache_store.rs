use crate::platform::file_security::ensure_private_dir;
use anyhow::Result;

pub use lico_catalog_convergence::CatalogCacheStore;

pub fn open_catalog_cache_store() -> Result<CatalogCacheStore> {
    let root = crate::platform::paths::portable_data_dir()?.join("catalog-cache");
    ensure_private_dir(&root)?;
    CatalogCacheStore::open(root)
}
