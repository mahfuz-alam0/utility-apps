import InputMethodKit

private let notFound = NSRange(location: NSNotFound, length: NSNotFound)

/// One typing session. You type roman letters; the word so far is shown inline as marked text and as a
/// candidate list under the caret. Space/Return/punctuation commits the highlighted candidate.
@objc(BornoInputController)
final class InputController: IMKInputController {
  private var buffer = ""            // roman text of the current word
  private var candidates: [String] = []
  private var selected = 0
  private var picked = false         // user moved off the default candidate (so we learn the choice)

  override func recognizedEvents(_ sender: Any!) -> Int { Int(NSEvent.EventTypeMask.keyDown.rawValue) }

  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event, event.type == .keyDown else { return false }
    let composing = !buffer.isEmpty

    // Shortcuts (⌘ ⌃ ⌥) belong to the app: finish the word, let the key through.
    if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { commit(); return false }

    switch event.keyCode {
    case 36, 76: guard composing else { return false }; commit(); return true           // return, enter
    case 49: guard composing else { return false }; commit(" "); return true            // space
    case 53: guard composing else { return false }; cancel(); return true               // escape
    case 51:                                                                            // delete
      guard composing else { return false }
      buffer.removeLast()
      buffer.isEmpty ? cancel() : refresh()
      return true
    case 48: guard composing else { return false }; move(event.modifierFlags.contains(.shift) ? -1 : 1); return true
    case 125: guard composing else { return false }; move(1); return true               // down
    case 126: guard composing else { return false }; move(-1); return true              // up
    default: break
    }

    guard let s = event.characters, s.count == 1, let c = s.first,
      c.isASCII, c.isLetter || c.isNumber || "`^:.,$".contains(c)
    else { commit(); return false }   // arrows, other punctuation, ...: finish the word, key goes through

    // After . or , a new word starts, except "." between digits (3.5) and the ".` ,," combos.
    if let last = buffer.last, ".,".contains(last) {
      let decimal = last == "." && c.isNumber && buffer.dropLast().last?.isNumber == true
      if !decimal, !".,`".contains(c) { commit() }
    }
    buffer.append(c)
    refresh()
    return true
  }

  override func commitComposition(_ sender: Any!) { commit() }

  override func deactivateServer(_ sender: Any!) {
    commit()
    super.deactivateServer(sender)
  }

  // MARK: composing

  /// Trailing "." and "," are punctuation, not part of the word that gets looked up.
  private var split: (core: String, tail: String) {
    let tail = String(buffer.reversed().prefix { ".,".contains($0) }.reversed())
    return (String(buffer.dropLast(tail.count)), Phonetic.transliterate(tail))
  }

  private func refresh() {
    let (core, _) = split
    candidates = core.isEmpty ? [""] : Lexicon.shared.suggest(core)
    selected = 0
    picked = false
    render()
  }

  private func render() {
    let tail = split.tail
    let text = candidates[selected] + tail
    client()?.setMarkedText(
      NSAttributedString(string: text, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
      selectionRange: NSRange(location: text.utf16.count, length: 0), replacementRange: notFound)

    var caret = NSRect.zero
    _ = client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
    let panel = CandidatePanel.shared
    panel.onPick = { [weak self] i in self?.selected = i; self?.picked = true; self?.commit() }
    panel.show(header: buffer, items: candidates.map { $0 + tail }, selected: selected, caret: caret)
  }

  private func move(_ delta: Int) {
    selected = (selected + delta + candidates.count) % candidates.count
    picked = true
    render()
  }

  private func commit(_ suffix: String = "") {
    guard !buffer.isEmpty else { return }
    let (core, tail) = split
    if picked, !core.isEmpty { Lexicon.shared.learn(core, candidates[selected]) }
    client()?.insertText(candidates[selected] + tail + suffix, replacementRange: notFound)
    reset()
  }

  private func cancel() {
    client()?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
    reset()
  }

  private func reset() {
    buffer = ""; candidates = []; selected = 0; picked = false
    CandidatePanel.shared.hide()
  }
}
