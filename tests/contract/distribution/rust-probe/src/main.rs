//! Executes the product's real `install_closure` and capability ownership
//! decisions so the plan-side resolver can be compared against them instead of
//! against a copy of their source text.
//!
//! Two modes, both machine-readable on stdout, one JSON value per line:
//!
//! ```text
//! licoup-distribution-probe vectors <catalogue-cases.json>
//! licoup-distribution-probe capabilities
//! ```
//!
//! It does not install, download, execute or delete anything, and it holds no
//! state: every invocation is a pure function of the documents it is given.

use std::fs;
use std::process::ExitCode;

use licoup_extension_contracts::deployment::{
    LocalCatalogue, PackOwnership, PackageEntry, PackageSource, capability_owner,
    core_capabilities, install_closure, optional_capabilities,
};
use licoup_extension_contracts::manifest::Dependency;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct VectorFile {
    cases: Vec<VectorCase>,
}

#[derive(Deserialize)]
struct VectorCase {
    id: String,
    catalogue: CatalogueInput,
    roots: Vec<String>,
}

#[derive(Deserialize)]
struct CatalogueInput {
    packages: Vec<PackageInput>,
}

#[derive(Deserialize)]
struct PackageInput {
    id: String,
    version: Option<String>,
    source: Option<String>,
    #[serde(default)]
    requires: Vec<DependencyInput>,
    #[serde(default, rename = "optionalRequires")]
    optional_requires: Vec<DependencyInput>,
}

#[derive(Deserialize)]
struct DependencyInput {
    #[serde(rename = "packageId")]
    package_id: String,
    range: Option<String>,
}

fn source_of(id: Option<&str>) -> PackageSource {
    match id {
        Some("local-import") => PackageSource::LocalImport,
        Some("local-directory") => PackageSource::LocalDirectory,
        Some("third-party-directory") => PackageSource::ThirdPartyDirectory,
        _ => PackageSource::OfficialDirectory,
    }
}

fn dependency(input: &DependencyInput) -> Dependency {
    Dependency::new(
        input.package_id.as_str(),
        input.range.as_deref().unwrap_or("*"),
    )
}

fn run_vectors(path: &str) -> Result<Vec<Value>, String> {
    let text = fs::read_to_string(path).map_err(|error| format!("{path}: {error}"))?;
    let parsed: VectorFile = serde_json::from_str(&text)
        .map_err(|error| format!("{path} is not a vector file: {error}"))?;
    let mut results = Vec::new();
    for case in parsed.cases {
        let mut catalogue = LocalCatalogue::new();
        for package in case.catalogue.packages {
            let version = package.version.unwrap_or_else(|| "0.0.0".to_owned());
            let entry = PackageEntry::new(
                package.id.as_str(),
                version.as_str(),
                source_of(package.source.as_deref()),
            )
            .requiring(package.requires.iter().map(dependency))
            .optionally_requiring(package.optional_requires.iter().map(dependency));
            catalogue.insert(entry);
        }
        let roots: Vec<&str> = case.roots.iter().map(String::as_str).collect();
        let value = match install_closure(&catalogue, &roots) {
            Ok(closure) => json!({
                "id": case.id,
                "ok": true,
                "selected": closure.selected().collect::<Vec<_>>(),
                "declined_optional": closure.declined_optional().collect::<Vec<_>>(),
            }),
            Err(failure) => json!({
                "id": case.id,
                "ok": false,
                "code": failure.code,
                "package": failure.presentation_args.get("package"),
                "required_by": failure.presentation_args.get("requiredBy"),
                "field": failure.field,
            }),
        };
        results.push(value);
    }
    Ok(results)
}

fn run_capabilities() -> Vec<Value> {
    let mut rows: Vec<Value> = core_capabilities()
        .chain(optional_capabilities())
        .map(|capability| {
            let (owner, set) = match capability_owner(capability) {
                Some(PackOwnership::Core(package)) => (package, "core"),
                Some(PackOwnership::Optional(package)) => (package, "optional"),
                None => ("", "absent"),
            };
            json!({ "capability": capability, "owner": owner, "set": set })
        })
        .collect();
    rows.sort_by(|left, right| {
        left["capability"]
            .as_str()
            .cmp(&right["capability"].as_str())
    });
    rows
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result: Result<Vec<Value>, String> = match args.first().map(String::as_str) {
        Some("vectors") if args.len() == 2 => run_vectors(args[1].as_str()),
        Some("capabilities") if args.len() == 1 => Ok(run_capabilities()),
        _ => {
            eprintln!("usage: licoup-distribution-probe vectors <file> | capabilities");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(values) => {
            for value in values {
                println!("{}", serde_json::to_string(&value).expect("serialize"));
            }
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("{message}");
            ExitCode::from(2)
        }
    }
}
