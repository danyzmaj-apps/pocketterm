import XCTest

@testable import PocketTermKit

final class AnsiTests: XCTestCase {
  let c = TermColors.fallback

  private func text(_ spans: [AnsiSpan]) -> String { spans.map(\.text).joined() }

  func testVectorColorsAreTheFallback() {
    let colors = Vectors.section("ansi")["colors"]!
    XCTAssertEqual(c.foreground.hex, colors["foreground"]?.string)
    XCTAssertEqual(c.background.hex, colors["background"]?.string)
    XCTAssertEqual(c.palette.map(\.hex), colors["palette"]?.strings)
    XCTAssertEqual(colors["palette"]?.array?.count, 256)
  }

  func testVectorTermColorsFromJson() throws {
    let v = Vectors.section("ansi")["termColorsFromJson"]!
    let colors = try XCTUnwrap(TermColors(json: v["input"]!.object!))
    XCTAssertEqual(colors.foreground.hex, v["foreground"]?.string)
    XCTAssertEqual(colors.background.hex, v["background"]?.string)
    XCTAssertEqual(colors.palette.map(\.hex), v["palette"]?.strings)
  }

  func testVectorCases() {
    let cases = Vectors.cases("ansi")
    XCTAssertEqual(cases.count, 30)
    for v in cases {
      let note = v["note"]?.string ?? ""
      let got = ansiSpans(v["input"]!.string!, c)
      let want = v["spans"]!.array!
      XCTAssertEqual(got.count, want.count, note)
      for (g, w) in zip(got, want) {
        XCTAssertEqual(g.text, w["text"]?.string, note)
        XCTAssertEqual(g.fg.hex, w["fg"]?.string, note)
        XCTAssertEqual(g.bg?.hex, w["bg"]?.string, note)
        XCTAssertEqual(g.bold, w["bold"]?.bool, note)
        XCTAssertEqual(g.italic, w["italic"]?.bool, note)
        XCTAssertEqual(g.decoration?.rawValue, w["decoration"]?.string, note)
      }
    }
  }

  func testTruecolorInKittyColonFormAndInSemicolonForm() {
    let spans = ansiSpans("\u{1b}[38:2:0:180:255ma\u{1b}[38;2;1;2;3;48;5;196mb\u{1b}[0mc", c)
    XCTAssertEqual(text(spans), "abc")
    XCTAssertEqual(spans[0].fg, TermColor(argb: 0xFF00_B4FF))
    XCTAssertEqual(spans[1].fg, TermColor(argb: 0xFF01_0203))
    XCTAssertEqual(spans[1].bg, c.palette[196])
    XCTAssertEqual(spans[2].fg, c.foreground)
    XCTAssertNil(spans[2].bg)
  }

  func testAttributesOnAndOffBasicAndBrightColors() {
    let spans = ansiSpans("\u{1b}[1;31ma\u{1b}[22;39;94mb", c)
    XCTAssertTrue(spans[0].bold)
    XCTAssertEqual(spans[0].fg, c.palette[1])
    XCTAssertFalse(spans[1].bold)
    XCTAssertEqual(spans[1].fg, c.palette[12])
  }

  func testHyperlinksPromptMarksAndOtherEscapesLeaveOnlyTheirText() {
    let spans = ansiSpans("\u{1b}]133;A\u{1b}\\\u{1b}]8;id=1;file:///x\u{1b}\\link\u{1b}]8;;\u{1b}\\ \u{1b}[2Kend", c)
    XCTAssertEqual(text(spans), "link end")
  }

  func testEscapesWithIntermediatesLeaveNothing() {
    let spans = ansiSpans("\u{1b}(B\u{1b}[32ma\u{1b}(0\u{1b}#8b\u{1b}7c", c)
    XCTAssertEqual(text(spans), "abc")
    XCTAssertEqual(spans.first?.fg, c.palette[2])
  }

  func testACutOffEscapeAtTheEndLeaksNoneOfItsBytes() {
    for cut in ["\u{1b}]8;;https://example.com/a", "\u{1b}[38;2;1", "\u{1b}"] {
      XCTAssertEqual(text(ansiSpans("text\(cut)", c)), "text", cut)
    }
    // An OSC whose terminator never came, followed by the next escape.
    XCTAssertEqual(text(ansiSpans("\u{1b}]0;title\u{1b}[31mred", c)), "red")
  }

  func testACutOffCsiBeforeALineBreakIsNotTakenAsCutOff() {
    // Dart's `$` matches only at the very end; the line break and what follows stay text.
    XCTAssertEqual(text(ansiSpans("a\u{1b}[1\nb", c)), "a1\nb")
  }

  func testKittyGraphicsAndTmuxPassthroughLeaveNothingOfTheirPayload() {
    let spans = ansiSpans("a\u{1b}_Gf=100,a=T;iVBORw0KGgo=\u{1b}\\b\u{1b}Ptmux;\u{1b}\u{1b}]52;c;eA==\u{07}\u{1b}\\c", c)
    XCTAssertEqual(text(spans), "abc")
  }

  func testPrivateModesKeyboardModesAndMissing256IndexDrawNothing() {
    let spans = ansiSpans("\u{1b}[?2004h\u{1b}[>4;2m\u{1b}[=1;u\u{1b}[38;5ma\u{1b}[48;5;999mb", c)
    XCTAssertEqual(text(spans), "ab")
    XCTAssertNil(spans.last?.bg)
  }

  func testAShortReportedPaletteLeavesTheDefaultColor() {
    let short = TermColors(foreground: c.foreground, background: c.background, palette: [c.palette[0]])
    XCTAssertEqual(ansiSpans("\u{1b}[31mx", short).first?.fg, c.foreground)
  }
}
