/// Strips a leading/trailing Markdown-style code fence (```` ``` ```` or
/// ```` ```json ````) from `text`, returning the inner payload trimmed of
/// surrounding whitespace.
///
/// LLMs occasionally wrap JSON in a fence even when asked not to;
/// ``ContextExtractor`` and ``AnalysisRunner`` both call through here
/// before handing the payload to `JSONDecoder`.
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
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
