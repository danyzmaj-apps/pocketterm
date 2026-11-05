import PocketTermKit
import XCTest

/// agent.dart: vectors.json's `live.agent`, then agent_test.dart.
final class AgentTests: XCTestCase {
  func testVectorAgents() {
    let v = TermVectors.at("live", "agent")
    let agents = v["agents"]!.array!
    XCTAssertEqual(agents.map { $0["name"]!.string! }, Agent.allCases.map(\.name))
    for a in agents {
      let agent = Agent(rawValue: a["name"]!.string!)!
      XCTAssertEqual(agent.label, a["label"]?.string)
      XCTAssertEqual(agent.command, a["command"]?.string)
      XCTAssertEqual(agent.steers, a["steers"]?.bool)
      XCTAssertEqual(Array(agent.resume.utf16), Array(a["resume"]!.string!.utf16))
      XCTAssertEqual(Array(agent.pickUp.utf16), Array(a["pickUp"]!.string!.utf16))
      for (profile, want) in a["commandIn"]?.object ?? [:] { XCTAssertEqual(agent.commandIn(profile), want.string) }
      for (profile, want) in a["labelIn"]?.object ?? [:] { XCTAssertEqual(agent.labelIn(profile), want.string) }
      for (profile, want) in a["resumeIn"]?.object ?? [:] {
        XCTAssertEqual(Array(agent.resumeIn(profile).utf16), Array(want.string!.utf16))
      }
      for (profile, want) in a["pickUpIn"]?.object ?? [:] {
        XCTAssertEqual(Array(agent.pickUpIn(profile).utf16), Array(want.string!.utf16))
      }
    }
    for c in v["parse"]!.array! {
      XCTAssertEqual(Agent.parse(c["input"]).name, c["agent"]!.string!, TermVectors.note(c))
    }
    for c in v["ofProgram"]!.array! {
      XCTAssertEqual(Agent.ofProgram(c["input"]!.string!)?.name, c["agent"]?.string, TermVectors.note(c))
    }
    for c in v["sessionOfTitle"]!.array! {
      let agent = Agent(rawValue: c["agent"]!.string!)!
      XCTAssertEqual(agent.sessionOfTitle(c["title"]!.string!), c["session"]?.string, c["title"]!.string!)
    }
    for c in v["isOmpProfile"]!.array! {
      XCTAssertEqual(isOmpProfile(c["input"]!.string!), c["ok"]!.bool!, c["input"]!.string!)
    }
    for c in v["ompProfileOfArgs"]!.array! {
      XCTAssertEqual(ompProfileOfArgs(c["args"]!.string!), c["profile"]!.string!, c["args"]!.string!)
    }
  }

  func testAnOmpCommandLinesProfileWhicheverWayItsWritten() {
    XCTAssertEqual(ompProfileOfArgs("omp --profile=personal"), "personal")
    XCTAssertEqual(ompProfileOfArgs("/opt/homebrew/bin/omp --profile work -c"), "work")
    XCTAssertEqual(ompProfileOfArgs("omp --profile=Work"), "")
    XCTAssertEqual(ompProfileOfArgs("omp --profile"), "")
    XCTAssertEqual(ompProfileOfArgs("omp --resume /x.jsonl"), "")
    XCTAssertEqual(ompProfileOfArgs("omp"), "")
    XCTAssertEqual(ompProfileOfArgs("omp --profile=work --profile personal"), "personal", "the last one, as omp")
    XCTAssertEqual(ompProfileOfArgs("omp --profile=work -- --profile x"), "work", "nothing after --")
    XCTAssertEqual(ompProfileOfArgs("omp --profile=default"), "")
  }

  func testProfileNamesAsOmpTakesThem() {
    XCTAssertTrue(isOmpProfile("personal"))
    XCTAssertTrue(isOmpProfile("a.b_c-1"))
    XCTAssertFalse(isOmpProfile("a."))
    XCTAssertFalse(isOmpProfile(".a"))
    XCTAssertFalse(isOmpProfile(""))
    XCTAssertFalse(isOmpProfile("a; rm -rf ~"))
    XCTAssertFalse(isOmpProfile(String(repeating: "a", count: 65)))
  }

  func testOnlyOmpRunsInAProfileAndTheDefaultOneReadsAsBefore() {
    XCTAssertEqual(Agent.omp.commandIn("personal"), "omp --profile=personal")
    XCTAssertEqual(Agent.omp.commandIn(""), "omp")
    XCTAssertEqual(Agent.claude.commandIn("personal"), "claude")
    XCTAssertEqual(Agent.omp.labelIn("personal"), "omp · personal")
    XCTAssertEqual(Agent.omp.labelIn(""), "omp")
    XCTAssertEqual(Agent.claude.labelIn("personal"), "Claude")
    // As typed once the no-break characters are gone.
    func typed(_ s: String) -> String {
      s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2060}", with: "")
    }
    XCTAssertEqual(typed(Agent.omp.resumeIn("personal")), "omp --profile=personal -c")
    XCTAssertEqual(Agent.omp.resumeIn(""), Agent.omp.resume)
    XCTAssertEqual(Agent.claude.pickUpIn("personal"), "/reload-plugins")
  }
}
