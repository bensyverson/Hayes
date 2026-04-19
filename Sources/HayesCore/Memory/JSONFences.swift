/// Isolates the JSON payload inside an LLM response.
///
/// First strips a leading/trailing Markdown-style code fence (```` ``` ```` or
/// ```` ```json ````). Then trims any conversational preamble or postamble
/// around the JSON body by slicing from the first `{` or `[` to the matching
/// last `}` or `]` — the two shapes Hayes's memory stages ask for. LLMs
/// occasionally prefix a response with "Here's the JSON:" or append a short
/// explanation; both are tolerated.
///
/// If no object or array delimiter is found, returns the fence-stripped text
/// verbatim so the caller's `JSONDecoder` can raise the specific error.
func stripJSONFences(_ text: String) -> String {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("```") {
        if let firstNewline = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: firstNewline)...])
        } else {
            s = String(s.dropFirst(3))
        }
    }
    if s.hasSuffix("```") {
        s = String(s.dropLast(3))
    }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)

    // If the LLM wrapped the JSON in prose, locate the outermost object or
    // array block and trim to it. Picks whichever delimiter appears first;
    // the closing counterpart is the *last* occurrence so nested braces
    // don't truncate the payload early.
    let firstBrace = s.firstIndex(of: "{")
    let firstBracket = s.firstIndex(of: "[")
    let start: String.Index?
    let closing: Character
    switch (firstBrace, firstBracket) {
    case let (b?, k?):
        if b < k {
            start = b
            closing = "}"
        } else {
            start = k
            closing = "]"
        }
    case let (b?, nil):
        start = b
        closing = "}"
    case let (nil, k?):
        start = k
        closing = "]"
    default:
        return s
    }
    guard let start, let end = s.lastIndex(of: closing), end >= start else {
        return s
    }
    return String(s[start ... end])
}
