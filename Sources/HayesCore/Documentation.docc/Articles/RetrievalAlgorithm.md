# The Retrieval Algorithm

How Hayes selects relevant seeds and behaviors from the memory graph.

## Overview

Retrieval is the query-side pipeline that turns a set of context embeddings into a
``RetrievalResult``. It runs entirely in-process, using an in-memory embedding cache
for cosine similarity plus the SQLite-backed edge graph for traversal.

## The algorithm

Given one or more context embeddings:

1. **Score every corpus node.** For each embedded node in the graph, compute the
   maximum cosine similarity against the provided context embeddings.
2. **Select seeds.** Keep nodes whose best similarity meets
   ``RetrievalConfig/seedThreshold``. Cap the list at
   ``RetrievalConfig/topSeeds``.
3. **Traverse.** For every seed, follow outgoing edges whose weight meets
   ``RetrievalConfig/minEdgeWeight``. Sum the weights per distinct target.
4. **Rank behaviors.** Sort target nodes by summed weight; take the top
   ``RetrievalConfig/topBehaviors``.

The output is a ``RetrievalResult`` with ranked seeds (scored by cosine similarity)
and ranked behaviors (scored by summed incoming edge weight).

## Complexity

At under ~1000 nodes, the brute-force cosine pass is sub-millisecond on modern
Apple silicon. No vector index is maintained.

## Tunables

Every threshold, cap, and weight lives on ``RetrievalConfig`` so configurations can
be serialized and swapped as a unit.
