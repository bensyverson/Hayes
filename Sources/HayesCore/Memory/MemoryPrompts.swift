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

    If the user message includes a CURRENT WORKING CONTEXT section with
    prior phrases, treat this as a conversational revision rather than a
    cold-start inference. Keep the zoomed-out framing; drop phrases that
    are no longer load-bearing for the latest turn; add newly-relevant
    phrases. Return the complete updated set (3-5 phrases total), not a
    diff.
    """

    /// System prompt for ``AnalysisRunner``.
    ///
    /// Tool-call oriented: the only correct output is a single invocation
    /// of the `submit_analysis` tool. Worked examples frame the JSON as
    /// the `lessons` argument, not as a text response, because small
    /// models (AFM in particular) pattern-match on example framing and
    /// will emit JSON text if the prompt reads as "produce this JSON."
    public static let analysis: String = """
    Your task is to call the `submit_analysis` tool with the lessons
    distilled from this turn. Calling the tool IS the output — do NOT
    emit any text, JSON, markdown, or explanation alongside or instead of
    the tool call.

    You are analyzing a single turn of an AI design agent to extract
    lessons that should be learned from it.

    Input:
    - CONVERSATION: the full message slice for the current turn, as
      JSON, starting from the most recent user message and including
      every assistant reply, tool call, and tool result in order.
      Binary content (images, PDFs, audio, video) is replaced with
      short text placeholders like `[redacted image/png]`.
    - THINKING TRACE: the agent's concatenated thinking across all
      LLM calls in the turn. May be empty — in which case infer what
      the agent did from the CONVERSATION alone (especially tool
      calls and their arguments).

    The `lessons` argument to submit_analysis is a list of objects,
    each with four fields:
      - seed: a short phrase (2-8 words) describing the kind of work
        or context — e.g. "electrolyte drink website", "typography
        for wellness brands", "minimal spa landing page". This is
        the *context*, not the user's literal words. If the user
        said "I hate Arial" while the agent was designing a beverage
        site, the seed is the beverage site, not the complaint.
      - behavior: a short phrase (2-8 words) naming the specific
        choice, technique, or element the lesson attaches to — e.g.
        "Arial body copy", "Georgia serif typeface", "gradient
        background". Behaviors are concrete.
      - sentiment: a number in [-1.0, 1.0]. Magnitude scales with
        strength: "hate" → -0.9, "not a fan" → -0.4, "pretty good"
        → 0.5, "love" → 0.9.
      - source: "user" if the signal came from the user's message,
        "self_assessment" if it came from the agent's thinking trace.

    What to look for:
      - Any evaluative signal in the user's message — praise,
        criticism, preference, dislike. Users rarely flag acts
        explicitly; they react to elements, choices, or outcomes.
        Emit one lesson per distinct reaction.
      - Any evaluative signal in the thinking trace — moments where
        the agent expresses satisfaction with, or identifies a
        problem with, something it (or a prior turn) did.

    Retroactive capture is the norm, not the exception. The agent
    may have used a font, color, or layout without flagging it as a
    deliberate move. When the user reacts to it, emit a lesson
    naming the behavior the user is actually responding to — even if
    no prior turn logged it.

    Worked example. The agent designs an electrolyte drink site
    using Arial for body copy, without flagging Arial explicitly.
    The user then says: "Oh cool. I hate Arial."
    Call submit_analysis with this `lessons` argument:
    [
      {"seed": "electrolyte drink website", "behavior": "bold glow headline treatment", "sentiment": 0.6, "source": "user"},
      {"seed": "electrolyte drink website", "behavior": "Arial body copy", "sentiment": -0.8, "source": "user"}
    ]
    The positive lesson attaches to the overall design the user
    approved of; the negative one is retroactive capture of the
    Arial choice the user disliked.

    Worked example for self_assessment. The thinking trace contains
    "I think the green CTA button looks flat; the old gold version
    had more presence." Call submit_analysis with this `lessons`
    argument:
    [
      {"seed": "landing page CTA button", "behavior": "green CTA button color", "sentiment": -0.5, "source": "self_assessment"}
    ]

    Pass an empty `lessons` list ONLY when the turn carries no
    evaluative content at all (e.g. a new neutral request, a pure
    clarifying question). This case is rare — most turns contain at
    least one implicit signal. Even an empty list must be delivered
    via submit_analysis; never skip the tool call.
    """
}
