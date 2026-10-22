/// Errors are returned to the calling thread. Render communicates numeric receipts,
/// never formatted diagnostics. No runtime implementation is implied by this set.
pub const MusicError = error{
    InvalidState,
    InvalidHandle,
    InvalidBankVersion,
    UnsupportedCapability,
    InvalidMusicGraph,
    InvalidTempo,
    MisalignedStems,
    TransitionNotFound,
    TargetNotResident,
    VoiceBudgetExceeded,
    CommandQueueFull,
    StaleAssetGeneration,
    StreamUnderrun,
    UnsupportedOperation,
};
