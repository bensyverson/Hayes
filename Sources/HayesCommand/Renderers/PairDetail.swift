import HayesCore

/// A surfaced view of a single (seed, behavior) edge with its endpoint
/// nodes pre-fetched.
///
/// The introspection / maintenance commands (`hayes inspect`, `ls`,
/// `forget`) read raw ``HayesCore/Edge`` rows from the graph store and
/// pair each with its endpoint ``HayesCore/Node``s before handing off
/// to ``PairRenderer``. Keeping the join explicit here means the
/// renderer is a pure function of pre-resolved data — no
/// ``HayesCore/GraphStore`` access in the formatting layer.
struct PairDetail {
    let seed: Node
    let behavior: Node
    let edge: Edge
}
