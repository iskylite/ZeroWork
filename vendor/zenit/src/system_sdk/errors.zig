/// System SDK error set
pub const SdkError = error{
    NotSupported,
    Unavailable,
    InvalidState,
    WrongThread,
    BufferTooSmall,
    Timeout,
    BackendFailure,
    OutOfMemory,
};
