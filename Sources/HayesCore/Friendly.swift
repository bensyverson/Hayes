/// A convenience typealias for values that are `Codable`, `Hashable`, `Equatable`, and `Sendable`.
///
/// Most public value types in HayesCore conform to `Friendly` so they can be freely
/// serialized, compared, hashed, and crossed across concurrency boundaries.
public typealias Friendly = Codable & Equatable & Hashable & Sendable
