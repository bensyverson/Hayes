import ArgumentParser
import Foundation
@testable import HayesCommand
import HayesCore
import Testing

@Suite("AssessCommand parsing")
struct AssessCommandParsingTests {
    @Test("requires at least one positional transcript path")
    func requiresTranscriptPath() {
        #expect(throws: (any Error).self) {
            _ = try AssessCommand.parse([])
        }
    }

    @Test("accepts a single transcript path")
    func acceptsSingle() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl"])
        #expect(cmd.transcripts == ["/tmp/t.jsonl"])
    }

    @Test("accepts multiple positional transcript paths")
    func acceptsMultiple() throws {
        let cmd = try AssessCommand.parse([
            "/tmp/a.jsonl", "/tmp/b.jsonl", "/tmp/c.jsonl",
        ])
        #expect(cmd.transcripts == ["/tmp/a.jsonl", "/tmp/b.jsonl", "/tmp/c.jsonl"])
    }

    @Test("defaults: strategy=parallel, concurrency=4, analyzer=anthropic, store-source=true, model=nil")
    func defaults() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl"])
        #expect(cmd.strategy == .parallel)
        #expect(cmd.concurrency == 4)
        #expect(cmd.analyzer == .anthropic)
        #expect(cmd.storeSource == true)
        #expect(cmd.model == nil)
        #expect(cmd.sessionID == nil)
        #expect(cmd.format == .auto)
    }

    @Test("--format opencode is captured")
    func formatOverride() throws {
        let cmd = try AssessCommand.parse(["/tmp/storage", "--format", "opencode"])
        #expect(cmd.format == .opencode)
    }

    @Test("--strategy one-shot parses")
    func strategyOneShot() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl", "--strategy", "one-shot"])
        #expect(cmd.strategy == .oneShot)
    }

    @Test("--concurrency override")
    func concurrencyOverride() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl", "--concurrency", "1"])
        #expect(cmd.concurrency == 1)
    }

    @Test("--analyzer afm parses")
    func analyzerAFM() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl", "--analyzer", "afm"])
        #expect(cmd.analyzer == .afm)
    }

    @Test("--model captured")
    func modelCaptured() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl", "--model", "claude-haiku-4-5"])
        #expect(cmd.model == "claude-haiku-4-5")
    }

    @Test("--no-store-source flag")
    func noStoreSourceFlag() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl", "--no-store-source"])
        #expect(cmd.storeSource == false)
    }

    @Test("--session-id captured")
    func sessionIDOverride() throws {
        let cmd = try AssessCommand.parse(["/tmp/t.jsonl", "--session-id", "abc-123"])
        #expect(cmd.sessionID == "abc-123")
    }

    @Test("--analyzer none is rejected at parse-time validation")
    func analyzerNoneRejected() {
        #expect(throws: (any Error).self) {
            _ = try AssessCommand.parse(["/tmp/t.jsonl", "--analyzer", "none"])
        }
    }

    @Test("--session-id with multiple transcripts is rejected")
    func sessionIDWithMultipleRejected() {
        #expect(throws: (any Error).self) {
            _ = try AssessCommand.parse([
                "/tmp/a.jsonl", "/tmp/b.jsonl", "--session-id", "abc",
            ])
        }
    }
}

@Suite("AssessCommand helpers")
struct AssessCommandHelpersTests {
    @Test("resolvedStrategy(.parallel) maps to AssessOptions.Strategy.parallel(concurrency:)")
    func strategyParallel() {
        let strategy = AssessCommand.resolveStrategy(.parallel, concurrency: 2)
        #expect(strategy == .parallel(concurrency: 2))
    }

    @Test("resolvedStrategy(.oneShot) maps to AssessOptions.Strategy.oneShot regardless of concurrency")
    func strategyOneShot() {
        let strategy = AssessCommand.resolveStrategy(.oneShot, concurrency: 99)
        #expect(strategy == .oneShot)
    }

    @Test("defaultTranscriptIdentity returns filename stem")
    func defaultIdentity() {
        let url = URL(fileURLWithPath: "/some/path/abc-uuid.jsonl")
        #expect(AssessCommand.defaultTranscriptIdentity(for: url) == "abc-uuid")
    }
}
