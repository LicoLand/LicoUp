//! Command line for the standalone migration tool.
//!
//! `inspect`, `plan`, `convert` and `resume` work on a data root. `export` and `import`
//! route to the client's own full-data-root archive owner; `import` writes into an empty
//! `--target-root` and therefore names no data root at all. `rehearse` reads one released
//! root and does all of its work in the disposable `--work-root` the caller names. Every
//! verb prints one JSON report with a stable `status` field, or a typed failure code, and
//! never prints a stored value.

use std::path::PathBuf;

/// One parsed invocation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Invocation {
    pub verb: Verb,
    /// The root named by `--data-root`. `import` has none: its destination is the empty
    /// `--target-root`, and the archive it reads is the only input it needs.
    pub data_root: Option<PathBuf>,
    pub target: Option<String>,
    pub json: bool,
    /// The operator's statement that every writer is stopped against the data root.
    pub writers_stopped: bool,
    /// The archive named by `--archive`, for the two archive verbs.
    pub archive: Option<PathBuf>,
    /// The destination named by `--target-root`, for import or snapshot preparation.
    pub target_root: Option<PathBuf>,
    /// The disposable working directory named by `--work-root`, for `rehearse`.
    pub work_root: Option<PathBuf>,
    /// Keep the rehearsal's disposable working root instead of removing it after the run.
    pub keep_work_root: bool,
    /// Explicitly activate a prepared peer recovery under the same exclusive lease.
    pub activate: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Verb {
    Inspect,
    Plan,
    Convert,
    Resume,
    Export,
    Import,
    Rehearse,
    RecoverPeerSnapshot,
}

/// What the caller asked for that the tool cannot honour.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Usage {
    Help,
    Version,
    UnknownVerb(String),
    MissingValue(&'static str),
    UnknownOption(String),
    DataRootRequired,
    ArchiveRequired,
    TargetRootRequired,
    WorkRootRequired,
    WritersStoppedRequired,
}

impl std::fmt::Display for Usage {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Help => formatter.write_str(HELP),
            Self::Version => formatter.write_str(env!("CARGO_PKG_VERSION")),
            Self::UnknownVerb(verb) => write!(formatter, "unknown_verb {verb}"),
            Self::MissingValue(option) => write!(formatter, "option_value_missing {option}"),
            Self::UnknownOption(option) => write!(formatter, "unknown_option {option}"),
            Self::DataRootRequired => formatter.write_str("data_root_required"),
            Self::ArchiveRequired => formatter.write_str("archive_required"),
            Self::TargetRootRequired => formatter.write_str("target_root_required"),
            Self::WorkRootRequired => formatter.write_str("work_root_required"),
            Self::WritersStoppedRequired => {
                formatter.write_str("maintenance_confirmation_required")
            }
        }
    }
}

pub const HELP: &str = "\
licoup-migrate: convert LicoUp local data between the fixed release endpoints

Usage:
  licoup-migrate inspect  --data-root <path> [--json]
  licoup-migrate plan     --data-root <path> [--target <name>] [--json]
  licoup-migrate convert  --data-root <path> --writers-stopped [--json]
  licoup-migrate resume   --data-root <path> --writers-stopped [--json]
  licoup-migrate export   --data-root <path> --archive <path>.zip|.tar.gz --writers-stopped [--json]
  licoup-migrate import   --archive <path> --target-root <empty directory> [--json]
  licoup-migrate rehearse --data-root <path> --work-root <directory> --writers-stopped [--keep-work-root] [--json]
  licoup-migrate recover-peer-snapshot --data-root <path> --target-root <new directory> --writers-stopped [--activate] [--json]

Commands:
  inspect  Report the domain state the client's own owners observe.
  plan     List the declared conversion steps owed by each domain.
  convert  Run the client's own conversion owner and report what it concluded.
  resume   Continue the conversion an interruption left unfinished.
  export   Capture the complete data root into one plaintext archive.
  import   Restore one archive into an empty destination.
  rehearse Convert a disposable copy of a released root, round-trip it through
           both plaintext containers, and report each stage it observed.
  recover-peer-snapshot
           Preserve an unpublished peer snapshot and prepare a separate current
           Conversation database. --activate also archives the complete original
           root and replaces only its Conversation database under the same lease.

Options:
  --data-root <path>  The data root to read. Required by every verb but import.
  --target <name>     Named target for the plan; defaults to the declared target.
  --archive <path>    The archive to write or read. The container is inferred from
                      the name. Required by export and import.
  --target-root <path>
                      The empty directory an import publishes into. Required by
                      import; a non-empty destination is refused. Snapshot recovery
                      instead requires a new output directory outside the source.
  --work-root <path>  The disposable directory a rehearsal stages, converts,
                      archives and restores in. Required by rehearse; the named
                      data root is never written to.
  --keep-work-root    Keep the rehearsal's working root after the run so a caller
                      can compare the roots each stage left on disk.
  --activate         Explicitly activate peer snapshot recovery. Without this flag,
                      recovery only prepares separate output and never changes source data.
  --writers-stopped   State that no writer is running against the data root. A
                      convert, resume, export, rehearsal and snapshot recovery require it: the
                      move, the capture and the rehearsal are only legitimate while
                      every writer is stopped.
  --json              Print JSON (the default; the flag is accepted for symmetry).
";

/// Parse an argument vector, excluding the program name.
pub fn parse(arguments: &[String]) -> Result<Invocation, Usage> {
    let mut verb: Option<Verb> = None;
    let mut data_root: Option<PathBuf> = None;
    let mut target: Option<String> = None;
    let mut json = false;
    let mut writers_stopped = false;
    let mut archive: Option<PathBuf> = None;
    let mut target_root: Option<PathBuf> = None;
    let mut work_root: Option<PathBuf> = None;
    let mut keep_work_root = false;
    let mut activate = false;

    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        match argument {
            "--help" | "-h" => return Err(Usage::Help),
            "--version" | "-V" => return Err(Usage::Version),
            "--json" => json = true,
            "--writers-stopped" => writers_stopped = true,
            "--keep-work-root" => keep_work_root = true,
            "--activate" => activate = true,
            "--data-root" | "--target" | "--archive" | "--target-root" | "--work-root" => {
                let value = arguments
                    .get(index + 1)
                    .filter(|value| !value.starts_with("--"))
                    .ok_or(Usage::MissingValue(match argument {
                        "--data-root" => "--data-root",
                        "--target" => "--target",
                        "--archive" => "--archive",
                        "--target-root" => "--target-root",
                        _ => "--work-root",
                    }))?;
                match argument {
                    "--data-root" => data_root = Some(PathBuf::from(value)),
                    "--target" => target = Some(value.clone()),
                    "--archive" => archive = Some(PathBuf::from(value)),
                    "--target-root" => target_root = Some(PathBuf::from(value)),
                    _ => work_root = Some(PathBuf::from(value)),
                }
                index += 1;
            }
            other if other.starts_with("--") => {
                return Err(Usage::UnknownOption(other.to_string()));
            }
            other => {
                let parsed = match other {
                    "inspect" => Verb::Inspect,
                    "plan" => Verb::Plan,
                    "convert" => Verb::Convert,
                    "resume" => Verb::Resume,
                    "export" => Verb::Export,
                    "import" => Verb::Import,
                    "rehearse" => Verb::Rehearse,
                    "recover-peer-snapshot" => Verb::RecoverPeerSnapshot,
                    unknown => return Err(Usage::UnknownVerb(unknown.to_string())),
                };
                if verb.is_some() {
                    return Err(Usage::UnknownVerb(other.to_string()));
                }
                verb = Some(parsed);
            }
        }
        index += 1;
    }

    let verb = verb.ok_or(Usage::Help)?;
    if activate && verb != Verb::RecoverPeerSnapshot {
        return Err(Usage::UnknownOption("--activate".to_owned()));
    }
    match verb {
        Verb::RecoverPeerSnapshot => {
            data_root.as_ref().ok_or(Usage::DataRootRequired)?;
            target_root.as_ref().ok_or(Usage::TargetRootRequired)?;
            if !writers_stopped {
                return Err(Usage::WritersStoppedRequired);
            }
        }
        // The archive verbs name the inputs their own boundary requires, and only those:
        // an import has no data root to read, and an export has no destination to publish.
        Verb::Import => {
            archive.as_ref().ok_or(Usage::ArchiveRequired)?;
            target_root.as_ref().ok_or(Usage::TargetRootRequired)?;
        }
        Verb::Export => {
            data_root.as_ref().ok_or(Usage::DataRootRequired)?;
            archive.as_ref().ok_or(Usage::ArchiveRequired)?;
        }
        // A conversion is the one verb that asks the client's owner to move data, so it
        // carries the operator's stopping statement; the tool's own lock cannot stop a
        // writer that never heard of it.
        Verb::Convert => {
            data_root.as_ref().ok_or(Usage::DataRootRequired)?;
            if !writers_stopped {
                return Err(Usage::WritersStoppedRequired);
            }
        }
        // The rehearsal drives the same owner as a conversion, so it makes the same
        // statement; it also names the disposable directory it works in, because a
        // rehearsal that picked one itself could write where the caller did not intend.
        Verb::Rehearse => {
            data_root.as_ref().ok_or(Usage::DataRootRequired)?;
            work_root.as_ref().ok_or(Usage::WorkRootRequired)?;
            if !writers_stopped {
                return Err(Usage::WritersStoppedRequired);
            }
        }
        Verb::Inspect | Verb::Plan | Verb::Resume => {
            data_root.as_ref().ok_or(Usage::DataRootRequired)?;
        }
    }
    Ok(Invocation {
        verb,
        data_root,
        target,
        json,
        writers_stopped,
        archive,
        target_root,
        work_root,
        keep_work_root,
        activate,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    #[test]
    fn parses_both_verbs() {
        let inspect = parse(&strings(&["inspect", "--data-root", "/tmp/root"])).expect("inspect");
        assert_eq!(inspect.verb, Verb::Inspect);
        assert_eq!(inspect.data_root.as_deref(), Some(Path::new("/tmp/root")));
        assert!(inspect.target.is_none());

        let plan = parse(&strings(&[
            "plan",
            "--data-root",
            "/tmp/root",
            "--target",
            "latest",
            "--json",
        ]))
        .expect("plan");
        assert_eq!(plan.verb, Verb::Plan);
        assert_eq!(plan.target.as_deref(), Some("latest"));
        assert!(plan.json);
    }

    #[test]
    fn parses_the_resume_verb_with_the_operators_statement() {
        let resume = parse(&strings(&[
            "resume",
            "--data-root",
            "/tmp/root",
            "--writers-stopped",
        ]))
        .expect("resume");
        assert_eq!(resume.verb, Verb::Resume);
        assert!(resume.writers_stopped);
        // Without the statement the invocation still parses; the verb is what refuses the
        // run, because the requirement belongs to the migration and not to the parser.
        let bare = parse(&strings(&["resume", "--data-root", "/tmp/root"])).expect("resume");
        assert!(!bare.writers_stopped);
    }

    #[test]
    fn parses_the_convert_verb_only_with_the_operators_statement() {
        let convert = parse(&strings(&[
            "convert",
            "--data-root",
            "/tmp/root",
            "--writers-stopped",
        ]))
        .expect("convert");
        assert_eq!(convert.verb, Verb::Convert);
        assert!(convert.writers_stopped);
        // The stopping statement belongs to the conversion, so the parser is where it is
        // required: a run that never made the statement must not reach the owner at all.
        assert_eq!(
            parse(&strings(&["convert", "--data-root", "/tmp/root"])),
            Err(Usage::WritersStoppedRequired)
        );
    }

    #[test]
    fn parses_the_archive_verbs_and_the_inputs_each_one_names() {
        let export = parse(&strings(&[
            "export",
            "--data-root",
            "/tmp/root",
            "--archive",
            "/tmp/backup.zip",
            "--writers-stopped",
        ]))
        .expect("export");
        assert_eq!(export.verb, Verb::Export);
        assert_eq!(
            export.archive.as_deref(),
            Some(Path::new("/tmp/backup.zip"))
        );
        assert!(export.writers_stopped);
        assert!(export.target_root.is_none());

        // An import reads one archive into an empty destination and names no data root.
        let import = parse(&strings(&[
            "import",
            "--archive",
            "/tmp/backup.tar.gz",
            "--target-root",
            "/tmp/restored",
        ]))
        .expect("import");
        assert_eq!(import.verb, Verb::Import);
        assert_eq!(
            import.archive.as_deref(),
            Some(Path::new("/tmp/backup.tar.gz"))
        );
        assert_eq!(
            import.target_root.as_deref(),
            Some(Path::new("/tmp/restored"))
        );
        assert!(import.data_root.is_none());
    }

    #[test]
    fn refuses_an_archive_verb_that_omits_an_input_it_needs() {
        assert_eq!(
            parse(&strings(&["export", "--data-root", "/tmp/root"])),
            Err(Usage::ArchiveRequired)
        );
        assert_eq!(
            parse(&strings(&["export", "--archive", "/tmp/backup.zip"])),
            Err(Usage::DataRootRequired)
        );
        assert_eq!(
            parse(&strings(&["import", "--target-root", "/tmp/restored"])),
            Err(Usage::ArchiveRequired)
        );
        assert_eq!(
            parse(&strings(&["import", "--archive", "/tmp/backup.zip"])),
            Err(Usage::TargetRootRequired)
        );
        assert_eq!(
            parse(&strings(&["import", "--archive"])),
            Err(Usage::MissingValue("--archive"))
        );
    }

    #[test]
    fn refuses_an_unknown_verb_option_and_missing_root() {
        assert_eq!(
            parse(&strings(&["migrate", "--data-root", "/tmp/root"])),
            Err(Usage::UnknownVerb("migrate".to_string()))
        );
        assert_eq!(
            parse(&strings(&[
                "inspect",
                "--data-root",
                "/tmp/root",
                "--watch"
            ])),
            Err(Usage::UnknownOption("--watch".to_string()))
        );
        assert_eq!(parse(&strings(&["inspect"])), Err(Usage::DataRootRequired));
        assert_eq!(
            parse(&strings(&["inspect", "--data-root"])),
            Err(Usage::MissingValue("--data-root"))
        );
        assert_eq!(parse(&strings(&["--help"])), Err(Usage::Help));
    }

    #[test]
    fn parses_the_rehearsal_verb_with_the_working_root_it_names() {
        let rehearse = parse(&strings(&[
            "rehearse",
            "--data-root",
            "/tmp/released",
            "--work-root",
            "/tmp/disposable",
            "--writers-stopped",
        ]))
        .expect("rehearse");
        assert_eq!(rehearse.verb, Verb::Rehearse);
        assert_eq!(
            rehearse.data_root.as_deref(),
            Some(Path::new("/tmp/released"))
        );
        assert_eq!(
            rehearse.work_root.as_deref(),
            Some(Path::new("/tmp/disposable"))
        );
        assert!(rehearse.writers_stopped);
        assert!(!rehearse.keep_work_root);
        // The source is only ever read, so the verb names no archive and no destination.
        assert!(rehearse.archive.is_none());
        assert!(rehearse.target_root.is_none());

        let keeping = parse(&strings(&[
            "rehearse",
            "--data-root",
            "/tmp/released",
            "--work-root",
            "/tmp/disposable",
            "--writers-stopped",
            "--keep-work-root",
        ]))
        .expect("rehearse");
        assert!(keeping.keep_work_root);
    }

    #[test]
    fn refuses_a_rehearsal_that_omits_its_working_root_or_the_stopping_statement() {
        assert_eq!(
            parse(&strings(&[
                "rehearse",
                "--data-root",
                "/tmp/released",
                "--writers-stopped"
            ])),
            Err(Usage::WorkRootRequired)
        );
        assert_eq!(
            parse(&strings(&[
                "rehearse",
                "--data-root",
                "/tmp/released",
                "--work-root",
                "/tmp/disposable"
            ])),
            Err(Usage::WritersStoppedRequired)
        );
        assert_eq!(
            parse(&strings(&["rehearse", "--work-root", "/tmp/disposable"])),
            Err(Usage::DataRootRequired)
        );
        assert_eq!(
            parse(&strings(&[
                "rehearse",
                "--data-root",
                "/tmp/released",
                "--work-root"
            ])),
            Err(Usage::MissingValue("--work-root"))
        );
    }
}
