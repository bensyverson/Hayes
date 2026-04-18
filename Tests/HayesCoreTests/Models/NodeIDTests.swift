@testable import HayesCore
import Testing

@Suite("NodeID")
struct NodeIDTests {
    @Test("make() produces a 6-character string")
    func length() {
        let id = NodeID.make()
        #expect(id.count == 6)
    }

    @Test("make() uses only characters from the alphabet")
    func charset() {
        let allowed = Set(NodeID.alphabet)
        for _ in 0 ..< 100 {
            let id = NodeID.make()
            for ch in id {
                #expect(allowed.contains(ch))
            }
        }
    }

    @Test("make() alphabet is 62 characters (a-z, A-Z, 0-9)")
    func alphabetSize() {
        #expect(NodeID.alphabet.count == 62)
    }

    @Test("1000 ids generated with no duplicates")
    func distribution() {
        var seen = Set<String>()
        for _ in 0 ..< 1000 {
            let id = NodeID.make()
            #expect(!seen.contains(id))
            seen.insert(id)
        }
        #expect(seen.count == 1000)
    }
}
