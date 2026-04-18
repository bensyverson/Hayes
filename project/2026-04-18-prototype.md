# Context Engine Prototype: One-Hour Build

## Goal

Test one hypothesis: **does an agent with a reinforced context-behavior graph produce better outputs and need fewer corrections than the same agent without one?**

## Non-Goals

- Frames, vector arithmetic, analogical reasoning
- Peer community / therapeutic agents
- Multi-level values (EEMM)
- Thinking trace extraction
- Event sourcing
- Production infrastructure

## Stack

- Swift (command-line tool, no UI)
- SQLite (in-process, no Postgres setup)
- LLM library for provider-agnostic model calls + embeddings
- Operator for the agent loop — lets us swap models easily

## Architecture

```
          ┌──────────────────────────────────┐
          │     Operator (Agent Loop)        │
          │                                  │
Brief ──→ │ Middleware: implicit retrieval    │
          │ Agent: generate, view, recall    │
          │ Middleware: extract + store       │
          └──────────────┬───────────────────┘
                         │
                ┌────────▼────────┐
                │  Context Engine │  SQLite + in-memory vectors
                │  ~200 lines     │  Registers as Operable
                └─────────────────┘
```

## Tools

### `recall` (explicit — agent chooses to use it)

The context engine registers as an `Operable` exposing one tool:

```swift
struct ContextEngine: Operable {
    var toolGroup: ToolGroup {
        ToolGroup(
            name: "Memory",
            description: "Recall past experience and attribute feedback",
            tools: [
                try Tool(
                    name: "recall",
                    description: """
                        Search your past experience. Two modes:

                        topic: Find relevant approaches from past work.
                        Use before making design decisions, or when you
                        want to check what has worked in similar contexts.

                        recent_acts: Find your recent work so you can
                        connect user feedback to the right past action.
                        Use when the user references something you did
                        previously.
                        """,
                    input: RecallInput.self
                ) { input in
                    switch input.mode {
                    case .topic:
                        // embed query, find seeds, traverse edges,
                        // return top behavior node texts
                    case .recentActs:
                        // query acts table, return act summaries
                        // with behavior node texts
                    }
                }
            ]
        )
    }
}

struct RecallInput: Codable {
    let mode: RecallMode
    let query: String?           // for topic search
    let since: TimeInterval?     // for recent_acts, e.g. 86400 = 24h
}

enum RecallMode: String, Codable {
    case topic
    case recentActs
}
```

The agent reaches for `recall` when it wants to — deliberate search for past approaches, or finding the right act to attribute feedback to. Most turns it won't use it.

### Implicit retrieval (middleware — agent doesn't see it)

Separate from the `recall` tool, the context engine also hooks into Operator's middleware to inject context automatically on every turn:

1. Intercepts the inbound message
2. Runs the context extraction LLM call ("what's the functional context?")
3. Embeds the context phrases, finds seeds, traverses edges
4. Injects a synthetic tool result with the top behavior texts
5. Agent sees the result but didn't request it — it just appears

Similarly, post-generation middleware:

1. Intercepts the agent's response
2. Extracts moves from the thinking trace (fast LLM call)
3. Creates/deduplicates nodes, creates edges
4. Saves the act record

The agent is unaware of both middleware passes. It sees past experience arrive as context (pre-generation), and its moves get remembered (post-generation), without doing anything.

## Data Model

### Nodes

```sql
CREATE TABLE nodes (
    id          TEXT PRIMARY KEY,     -- 6-char random: 'mZ8n_x'
    text        TEXT NOT NULL,        -- 'Using CSS grid', 'This user likes muted tones'
    embedding   BLOB                  -- [Float] serialized, computed async
);
```

### Edges

```sql
CREATE TABLE edges (
    source_id   TEXT NOT NULL REFERENCES nodes(id),
    target_id   TEXT NOT NULL REFERENCES nodes(id),
    weight      REAL NOT NULL DEFAULT 0.1,
    updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (source_id, target_id)
);
```

That's it. Two tables.

### Acts

A lightweight record of what was active during each generation. Closes the loop between extraction and reinforcement, including across sessions.

```sql
CREATE TABLE acts (
    id            TEXT PRIMARY KEY,      -- 6-char random like nodes
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    seed_ids      TEXT NOT NULL,         -- JSON array of context seed node IDs
    behavior_ids  TEXT NOT NULL,         -- JSON array of behavior node IDs
    status        TEXT NOT NULL DEFAULT 'pending'  -- 'pending', 'accepted', 'revised', 'rejected'
);
```

Three tables total.

### Node ID Generation

```swift
func makeID() -> String {
    let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    return String((0..<6).map { _ in chars.randomElement()! })
}
// Produces: "kT9x2v", "Mn4_pQ", "aX8rLw"
```

## Retrieval (Pre-Generation)

Two steps: extract the functional context, then find reinforced behaviors.

### Step 1: Context Extraction (fast LLM call)

The raw user message is too thin to seed retrieval well. A fast LLM call enriches it:

```
System: What is the functional context of this request?
        List 3-5 short phrases. JSON array of strings only.

User: "Design a yoga studio website"
```

Returns:
```json
["landing page design", "wellness brand", "calm minimal aesthetic", "small business website"]
```

This costs ~200 tokens round-trip with the fastest available model. It runs before the main generation call.

### Step 2: Seed → Traverse → Surface

```
Input: context phrases from step 1

1. Embed each context phrase
2. Cosine similarity against all node embeddings (brute force — fine for <1000 nodes)
3. Take top 5 seed nodes above threshold (e.g., 0.6)
4. For each seed, query outgoing edges with weight > 0.1
5. Collect target nodes, sum incoming weights from seeds
6. Deduplicate, rank by total weight
7. Take top 5 behavior nodes
8. Format as JSON and inject as tool result
```

At <1000 nodes, brute-force cosine similarity over in-memory floats is sub-millisecond on any modern machine. No index needed.

## Presentation to Model

```json
{
  "from_past_experience": [
    "CSS grid with relative units",
    "Muted earth tone palettes",
    "min-height instead of fixed height for hero sections",
    "clamp() for responsive typography",
    "This user prefers generous whitespace"
  ]
}
```

Just a list of short text strings. No structure, no scores, no metadata. The model sees hints, not instructions.

## Node Extraction (Post-Generation)

After the model generates (with extended thinking enabled), a fast LLM call extracts salient moves from the **thinking trace**, not from the output:

```
System: Read this reasoning trace from an AI agent. Extract 3-5 short
        phrases describing the key techniques, approaches, or design
        decisions the agent made. Focus on reusable moves, not
        task-specific details. Each phrase should be 2-8 words.
        Return only a JSON array of strings.

User: [thinking trace content]
```

Example thinking trace:
```
I'll use a narrow centered container — yoga feels intimate,
not corporate. For the palette I'll start from the warm browns
that worked for the spa client but shift slightly warmer. The
hero needs to handle variable content so I'll use min-height
with clamp() for the heading...
```

Example output:
```json
["narrow centered container", "warm earthy palette", "min-height hero section", "clamp() responsive typography", "intimate brand spacing"]
```

For each phrase:
1. Embed it
2. Check cosine similarity against existing nodes (threshold 0.85)
3. If match found → reuse existing node
4. If no match → create new node

Note: the thinking trace also contains *novel inferences* — generalizations like "warmer colors for wellness brands." These get extracted and stored as nodes alongside specific techniques. They're hypotheses. Future reinforcement will determine if they're useful.

## Edge Creation

Context nodes = seeds that were active during retrieval (from the context extraction step).
Behavior nodes = nodes extracted from the thinking trace.

Create edges: each context seed → each behavior node, with initial weight 0.1.

If edges already exist, leave them — reinforcement will update them.

## Reinforcement

### Step 1: Find the Right Act

Feedback can arrive at any time. The context engine provides the lookup; the agent does the interpretation.

**Same-turn feedback** (user responds immediately to a generation):
The most recent pending act is the target. No ambiguity.

**Later feedback** (same session or cross-session):
The agent calls the context engine's explicit query:

```swift
enum ContextQuery {
    case implicit(contextPhrases: [String])    // normal retrieval
    case recentActs(since: TimeInterval)        // feedback attribution
}
```

The context engine returns recent acts with their behavior node texts:

```json
{
  "recent_acts": [
    {
      "id": "aR7_kx",
      "created_at": "2026-04-17T14:30:00",
      "behaviors": ["warm earthy palette", "narrow container", "min-height hero"],
      "status": "accepted"
    },
    {
      "id": "bT3_mw",
      "created_at": "2026-04-17T11:15:00",
      "behaviors": ["bold blue accent color", "full-width hero", "geometric grid"],
      "status": "accepted"
    }
  ]
}
```

The agent sees the user's feedback alongside these act summaries and picks the match. "Yesterday's design was too blue" → `bT3_mw`. This is the agent reasoning, not the middleware guessing.

### Step 2: Update Edges

Once the target act is identified, reconstruct the active edges from `seeds × behaviors` and update:

**Positive (user accepts / says something positive):**
```swift
for edge in active_edges {
    edge.weight = min(1.0, edge.weight + 0.05 * confidence)
}
act.status = "accepted"
```

**Negative (user corrects / rejects):**
```swift
for edge in active_edges {
    edge.weight = max(0.0, edge.weight * (1.0 - 0.1 * confidence))
}
act.status = "revised" // or "rejected"
```

Confidence = 1.0 for explicit feedback ("I love this" / "change this").
Confidence = 0.5 for inferred feedback (agent self-corrects after viewing render).

## Test Protocol

### Setup
One design agent. System prompt for generating landing page HTML/CSS.

### A/B Comparison
Run two conditions across 10 design briefs each:

**Condition A (baseline):** Agent with no context engine. Fresh every time.

**Condition B (context engine):** Agent with context engine active. Graph accumulates across all 10 designs.

Same 10 briefs in both conditions. Same model, same temperature, same system prompt.

### Measurement
For each design:
1. Number of revision cycles before acceptable result
2. Did the first draft avoid known pitfalls? (binary, per pitfall)
3. Subjective quality rating of first draft (1-5, your judgment)

### What Success Looks Like
By designs 7-10 in condition B, measurably fewer revision cycles than condition A. Early designs (1-3) should show no difference — the graph hasn't learned yet.

### What Failure Looks Like
No difference by design 10, or condition B is actively worse (irrelevant suggestions confusing the model).

## The Full Loop

```
1. User brief arrives
2. MIDDLEWARE (pre-generation):
   a. Context extraction (fast LLM call, ~200 tokens)
      → ["landing page design", "wellness brand", ...]
   b. Embed context phrases → find seed nodes → traverse edges
   c. Inject top behaviors as synthetic tool result
3. GENERATION: Main model call with thinking enabled
   → model sees past experience in tool result
   → produces code + thinking trace
4. MIDDLEWARE (post-generation):
   a. Extract moves from thinking trace (fast LLM call, ~300 tokens)
      → ["narrow centered container", "warm earthy palette", ...]
   b. Deduplicate against existing nodes, create new ones, create edges
   c. Save act record: { seeds, behaviors, status: "pending" }
5. FEEDBACK: User accepts / revises / rejects
   - Same-turn → target is the most recent pending act
   - Later → agent calls recall(mode: .recentActs), picks the right act
6. Reinforce: update edge weights for that act's seed→behavior pairs
7. Update act status
```

Three LLM calls for generation (one pre-middleware, one main, one post-middleware). Feedback attribution is either automatic (same-turn) or uses the `recall` tool (later turns).

## Build Order

1. **SQLite schema + node/edge/act CRUD** (15 min)
   - Create three tables, insert/query functions
   - Node ID generation
   - Edge creation and weight update
   - Act recording and status update

2. **Context engine as Operable** (15 min)
   - `recall` tool with topic and recentActs modes
   - Embed a string via LLM library
   - Brute-force cosine similarity for seed finding
   - Seed → edge traversal → ranked behavior texts
   - Recent acts query with behavior summaries

3. **Middleware hooks** (15 min)
   - Pre-generation: context extraction LLM call → seed → traverse → synthetic tool result
   - Post-generation: thinking trace extraction LLM call → node dedup → edge creation → act save

4. **Operator integration + feedback loop** (15 min)
   - Wire ContextEngine as Operable into the Operative
   - Wire middleware into the agent loop
   - Manual feedback input after each generation (accept / revise / reject)
   - Feedback attribution: same-turn auto, later turns via recall
   - Weight updates + act status changes

## What This Doesn't Test

- Whether the system scales beyond hundreds of nodes
- Whether frames / analogical reasoning matter
- Whether peer agents improve flexibility
- Whether multi-level values are useful
- Whether the graph structure is better than a flat list of reinforced tips

That last one is important. A simpler baseline — just a growing list of "things that worked" injected into every prompt — might perform equally well. If the prototype succeeds, a follow-up test against the flat-list baseline would determine whether the graph structure (contextual reinforcement) adds value over simple accumulation.

## Addendum: Feedback Attribution

### Change Summary

Feedback attribution is handled entirely by middleware, not by the agent. The `recall` tool drops the `recentActs` mode — it only supports `topic` for deliberate experience search.

### Middleware Feedback Hook (pre-generation)

Before the normal context extraction step, a fast LLM call classifies whether the incoming message contains feedback on recent acts:

```
System: The user sent a message to an AI design agent.
        Below are the agent's recent actions. Did the user
        provide feedback on any of them?

        Return JSON only:
        {"feedback": [{"act_id": "...", "sentiment": 0.8}]}
        or {"feedback": []} if no feedback detected.
        Sentiment: -1.0 (strong negative) to 1.0 (strong positive).

User message: {user_message}

Recent acts:
{acts formatted as "- {id}: {behavior node texts}"}
```

If feedback is detected, update edges for each matched act before the main generation begins. Multiple acts can receive feedback from a single message (e.g., "love the layout but the colors are too intense" → positive for layout act, negative for palette act).

### Revised `recall` Tool

Single mode only:

```swift
struct RecallInput: Codable {
    let query: String  // "what has worked for wellness branding?"
}
```

No `mode` enum. No `recentActs`. The agent uses `recall` when it wants to search past experience by topic. Feedback attribution is invisible to the agent.

### Revised Full Loop

```
1. User message arrives
2. MIDDLEWARE (feedback):
   Fast LLM classifies message against recent acts
   → update edge weights for any matched acts
3. MIDDLEWARE (pre-generation):
   a. Context extraction (fast LLM call)
   b. Seed → traverse → inject synthetic tool result
4. GENERATION: Main model call with thinking
5. MIDDLEWARE (post-generation):
   a. Extract moves from thinking trace
   b. Create/dedup nodes, create edges, save act record
```

Steps 2 and 3 are separate middleware LLM calls. Step 2 can be skipped if there are no pending acts (e.g., first message in a session).

## Addendum: Self-Assessment

The post-generation middleware already extracts moves from the
thinking trace. After a `view_result` call, it additionally
checks for self-assessment:

```
System: The AI agent just viewed the result of its own work.
        Read its thinking. Did it identify any problems or
        express satisfaction?

        Return JSON only:
        {"assessment": 0.6}
        Sentiment: -1.0 (everything broken) to 1.0 (looks great).
        0.0 if no clear self-assessment.
```

If the sentiment is non-zero, attribute it to the current
pending act at lower confidence than user feedback:

```swift
// User feedback
reinforce(act: act, sentiment: sentiment, confidence: 1.0)

// Self-assessment
reinforce(act: act, sentiment: sentiment, confidence: 0.3)
```

Self-assessment gently shapes the graph. User feedback shapes
it strongly. The model noticing "the text is cut off" produces
a mild negative signal — not enough to dramatically alter
weights, but enough that over many iterations, approaches that
consistently produce self-assessed failures fade.

This also means the post-generation middleware does two things
after a `view_result`:
1. Extract moves (what techniques were used)
2. Extract self-assessment (did the model think it worked)

Both come from the same thinking trace. Could be one LLM call
with a combined prompt.

The nice thing: this means the graph learns even without user feedback. A model that generates, views, and self-corrects three times before the user ever sees it has already produced three rounds of low-confidence signal. The moves that survived self-review get mildly reinforced. The ones the model itself rejected get mildly decayed.
