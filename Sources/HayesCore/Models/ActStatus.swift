/// The lifecycle state of an ``Act``.
///
/// An act starts ``pending`` and transitions to ``accepted`` or ``revised`` once
/// feedback (user or self) has attributed success or regret. Acts that are
/// explicitly bad can be ``rejected``. Once an act leaves ``pending``, it is
/// no longer eligible for further attribution.
public enum ActStatus: String, Friendly {
    /// The act has not yet received attribution.
    case pending
    /// The act received positive attribution.
    case accepted
    /// The act received negative attribution.
    case revised
    /// The act was explicitly rejected.
    case rejected
}
