#  ``HayesCore``

Foundations for Hayes's automatic memory system: models, persistence, embeddings, and retrieval.

## Overview

`HayesCore` is the LLM-free core of Hayes. It provides the building blocks that the memory
middleware and CLI layer above it depend on:

- **Models** — ``Node``, ``Edge``, ``Act``, ``ActStatus`` — the memory graph's atoms.
- **Persistence** — ``GraphStore``, a SQLite-backed actor that owns the graph.
- **Embeddings** — ``EmbeddingProvider`` and the default ``NLEmbeddingProvider``
  that wraps Apple's English sentence embedding.
- **Cosine similarity** — ``cosineSimilarity(_:_:)``, accelerated with vDSP.
- **Retrieval** — a seed-then-traverse algorithm that uses the in-memory embedding
  cache plus the edge graph. See <doc:RetrievalAlgorithm>.
- **Reinforcement** — weight-update math applied after feedback. See <doc:ReinforcementMath>.

## Topics

### Models

- ``Node``
- ``Edge``
- ``Act``
- ``ActStatus``
- ``NodeID``
- ``Friendly``

### Embeddings

- ``EmbeddingProvider``
- ``NLEmbeddingProvider``
- ``cosineSimilarity(_:_:)``

### Graph store

- ``GraphStore``

### Retrieval

- ``RetrievalConfig``
- ``RetrievalResult``
- <doc:RetrievalAlgorithm>
- <doc:ReinforcementMath>

### Memory pipeline

- ``MemoryMiddleware``
- ``ContextExtractor``
- ``AnalysisRunner``
- ``AnalysisResult``
- ``ActFeedback``
- ``MiddlewareEvent``
- ``LLMClient``
- ``OperatorLLMClient``
- ``MemoryPrompts``
- <doc:MemoryPipeline>
