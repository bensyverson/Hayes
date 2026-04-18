/// Prompt constants used by Hayes's memory stages.
///
/// These are seed versions that mirror the examples in the prototype doc and
/// implementation plan. Prompts evolve empirically — treat rephrasing as a
/// measured experiment, not a "clarity" cleanup.
public enum MemoryPrompts {
    /// System prompt for ``ContextExtractor``.
    ///
    /// This is an *inference* prompt. The LLM is asked to produce enriched
    /// functional-context phrases that describe the kind of work being
    /// requested — not to copy phrases out of the input. The user-turn payload
    /// is a recent-conversation transcript (last N messages) so follow-ups
    /// like "make it warmer" can be interpreted against the preceding
    /// exchange.
    ///
    /// Canonical single-turn example (from the prototype doc):
    ///   "Design a yoga studio website"
    ///   → ["landing page design", "wellness brand",
    ///      "calm minimal aesthetic", "small business website"]
    public static let contextExtraction: String = """
    What is the functional context of the user's most recent request,
    given the conversation so far?
    List 3-5 short phrases describing the kind of work (domain, audience,
    aesthetic, project type). JSON array of strings only.
    """

    /// System prompt for ``AnalysisRunner``.
    ///
    /// Combines three tasks in a single call per turn:
    ///   - `moves`: reusable techniques + generalizations the agent used.
    ///   - `user_feedback`: attribution pulled from the user's message.
    ///   - `self_assessment`: attribution pulled from the agent's thinking.
    ///
    /// Both attribution lists reference the same `recent_acts` input and share
    /// the same shape. They differ only in the source scale applied at
    /// reinforcement time (``RetrievalConfig/userFeedbackScale`` vs.
    /// ``RetrievalConfig/selfAssessmentScale``).
    public static let analysis: String = """
    You are analyzing a single turn of an AI design agent.

    Input:
    - The user's message.
    - The agent's full thinking trace across all LLM calls in the turn.
    - A list of recent pending acts (id + behavior phrases + timestamp).

    Return JSON ONLY with this exact shape:
    {
      "moves": ["phrase", ...],
      "user_feedback": [{"act_id": "...", "sentiment": 0.7}, ...],
      "self_assessment": [{"act_id": "...", "sentiment": -0.3}, ...]
    }

    moves (3-5 items): short phrases (2-8 words each) naming:
      - Reusable techniques the agent used ("clamp() responsive typography").
      - Generalizations the agent articulated ("warmer colors for wellness brands").
    Both kinds go in the same array.

    user_feedback: if the user's message attributes success or failure to
    any prior act in the recent_acts list, emit one entry per attributed
    act with sentiment in [-1.0, 1.0]. Empty array if no such attribution.

    self_assessment: if the agent's thinking trace expresses satisfaction
    or identifies problems with any prior act in the recent_acts list,
    emit one entry per attributed act with sentiment in [-1.0, 1.0].
    Empty array if no such attribution.

    Both lists reference the SAME recent_acts. They differ only in source:
    user_feedback comes from the user's words; self_assessment comes from
    the agent's own thinking.
    """
}
