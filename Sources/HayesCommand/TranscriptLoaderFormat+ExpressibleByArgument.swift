import ArgumentParser
import HayesCore

/// Lets `TranscriptLoader.Format` be supplied as a `--format` value on the
/// command line. The default `ExpressibleByArgument` synthesis applies
/// because `Format` is a `String`-backed `RawRepresentable`, and its
/// `CaseIterable` conformance supplies the list of valid values for help
/// output and completion.
extension TranscriptLoader.Format: ExpressibleByArgument {}
