import AppKit
import Carbon
import Testing
@testable import Prompter

@Test func importExportAndEstimates() {
    let t = importSteps("preamble\n# A\npara one\ncontinued\n- b1\n> Show: x\n---\n# B\n")
    #expect(t.count == 3 && t[0].title.isEmpty && t[0].say == "preamble")
    #expect(t[1].title == "A" && t[1].say == "para one\ncontinued\n- b1" && t[1].cue == "x")
    #expect(t[2].title == "B" && t[2].say.isEmpty)
    #expect(t[1].items.map(\.kind) == [.p, .li, .cue])
    #expect(t[1].items.map(\.text) == ["para one continued", "b1", "Show: x"])
    let again = importSteps(exportText(Array(t[1...])))
    #expect(again.map(\.title) == ["A", "B"] && again.map(\.say) == [t[1].say, ""] && again.map(\.cue) == ["x", ""])
    #expect(Step(say: String(repeating: "word ", count: 30)).duration(wpm: 150) == 12)
    #expect(Step(say: "- \(String(repeating: "word ", count: 30))").duration(wpm: 150) == 12)  // bullet marker is not a word
    #expect(Step(say: "short").duration(wpm: 150) == 4 && Step(say: "short", seconds: 20).duration(wpm: 150) == 20)
    #expect(importSteps("# 2. Folder structure\nx").first?.title == "Folder structure")
    #expect(clock(75) == "1:15")
    #expect(buildContent(t[1], size: 26).string.hasPrefix("A\n"))
}

@Test func accelerators() {
    let a = parseAccel("CommandOrControl+Alt+P")
    #expect(a?.code == 35 && a?.mods == UInt32(cmdKey | optionKey))
    #expect(pretty("CommandOrControl+Shift+N") == "⌘⇧N")
}
