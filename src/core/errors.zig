//! Shared error sets used across zdms. Kept centralized so call sites can
//! match on a small, stable vocabulary instead of ad-hoc error names.

/// Errors that can occur while parsing CLI arguments.
pub const CliError = error{
    UnknownCommand,
    UnknownFlag,
    MissingArgument,
    TooManyArguments,
};

/// Errors that can occur while loading or validating configuration.
pub const ConfigError = error{
    InvalidValue,
    InvalidPath,
};

/// Errors that can occur while building, parsing, or verifying a .zpkg
/// package (manifest + archive).
pub const PackageError = error{
    InvalidManifest,
    CorruptArchive,
    UnsupportedFormatVersion,
    ChecksumMismatch,
};

/// Errors that can occur in the local package database or the
/// install/remove flow that uses it.
pub const DatabaseError = error{
    AlreadyInstalled,
    NotInstalled,
    CorruptEntry,
};

/// Errors from the repository layer: config, index parsing, and lookups.
pub const RepositoryError = error{
    NoRepositories,
    InvalidIndex,
    PackageNotFound,
    IndexNotFetched,
};

/// Errors from the downloader. Kept separate from RepositoryError so
/// retry/timeout policy can match on transport failures specifically.
pub const DownloadError = error{
    HttpError,
    RequestFailed,
    TooLarge,
};

/// Errors from the security layer: public key/signature parsing and
/// verification.
pub const SecurityError = error{
    InvalidPublicKey,
    InvalidSignature,
    SignatureMissing,
    SignatureInvalid,
};

/// Errors from the transaction/journal layer (`core/transaction.zig`).
pub const TransactionError = error{
    TransactionInProgress,
};

/// Non-zero exit signal from `zdms doctor` when it finds (but doesn't
/// fix) a problem -- lets scripts treat doctor like `fsck`.
pub const DoctorError = error{DoctorFoundProblems};

/// Placeholder for functionality slated for a later development phase.
/// Distinguishes "not built yet" from an actual runtime failure.
pub const NotImplemented = error{NotImplemented};
