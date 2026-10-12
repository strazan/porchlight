import Foundation
import Testing
@testable import PorchlightCore

/// Helping agents pick from many tools: what each server is for, and how many tools an app sees.
@Suite struct ManyToolsTests {
    @Test func instructionsSayWhatEachServerIsFor() async {
        var notes = fakeConfig("notes")
        notes.env["FAKE_INSTRUCTIONS"] = "Reads and writes the notes in the user's vault.\n\nUse search before get_note."
        await withRouter([notes, fakeConfig("plain")]) { h in
            await h.post(rpc(1, "tools/list")) // connects both servers

            let initialized = await h.post(initialize)
            let instructions = await initialized.json?["result"]?["instructions"]?.stringValue ?? ""
            #expect(instructions.contains("- notes: Reads and writes the notes in the user's vault."))
            #expect(!instructions.contains("get_note"))
            #expect(instructions.contains("- plain"))
        }
    }

    @Test func summariesAreOneShortLine() {
        let long = JSONValue.object(["instructions": .string(String(repeating: "word ", count: 80))])
        #expect(Aggregator.summary(of: long)?.count == Aggregator.summaryLength)
        let titled = JSONValue.object(["serverInfo": .object(["name": .string("x"), "title": .string("Obsidian  Notes")])])
        #expect(Aggregator.summary(of: titled) == "Obsidian Notes")
        #expect(Aggregator.summary(of: .object(["instructions": .string("  ")])) == nil)
        #expect(Aggregator.summary(of: nil) == nil)
    }

    @Test func countsWhatEachAppSees() async {
        var blocking = ToolPolicy(defaultPermission: .allowAll)
        blocking.overrides["remove"] = .deny
        await withRouter([queueConfig("alpha"), queueConfig("beta", policy: blocking)], access: ["chatgpt": ["beta"]]) { h in
            #expect(await h.router.toolCount(for: "") == 5)
            #expect(await h.router.toolCount(for: "chatgpt") == 2)
        }
    }
}
