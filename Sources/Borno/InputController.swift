import InputMethodKit

private let notFound = NSRange(location: NSNotFound, length: NSNotFound)

/// One typing session, behaving like iAvro 1.5's AvroKeyboardController. The roman text you type stays inline
/// (underlined); Bangla candidates show in a list under the caret, the one you highlighted last time for this
/// spelling preselected. Space, Return and Tab commit the highlighted candidate.
@objc(BornoInputController)
final class InputController: IMKInputController {
  private var buffer = ""                       // roman text typed so far, punctuation included
  private var prefix = "", term = "", suffix = ""   // buffer split; prefix and suffix already in Bangla
  private var candidates: [String] = []
  private var selected = 0
  private var prevSelected = -1                 // row of the remembered pick, -1 if none
  private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // key codes of 1...9

  private var lex: Lexicon { Lexicon.shared }

  override func menu() -> NSMenu! { BornoMenu.shared.menu }

  override func activateServer(_ sender: Any!) {
    super.activateServer(sender)
    lex.reloadIfUserWordsChanged()
  }

  override func recognizedEvents(_ sender: Any!) -> Int { Int(NSEvent.EventTypeMask.keyDown.rawValue) }

  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event, event.type == .keyDown else { return false }
    let composing = !buffer.isEmpty
    let mods = event.modifierFlags.intersection([.command, .control, .option])

    // ⌥1...⌥9 commit that row (Borno extra: iAvro's list has no shortcut).
    if composing, mods == .option, let n = Self.digitKeys.firstIndex(of: event.keyCode) {
      if n < candidates.count { highlight(n); commit() }
      return true
    }
    // ⌘⌫ (and ⌃⌫) delete the whole composition, list included; passing them on left the list open.
    if composing, event.keyCode == 51, mods.contains(.command) || mods.contains(.control) { cancel(); return true }
    if mods.contains(.command) || mods.contains(.control) { return false }   // shortcuts belong to the app

    if composing {
      switch event.keyCode {
      case 36, 76: commit(); return true                      // return, enter: commit, no new line
      case 48: commit("\t"); return true                      // tab
      case 49: commit(" "); return true                       // space
      case 53: cancel(); return true                          // escape
      case 51: buffer.removeLast(); refresh(); return true    // delete
      case 125: move(1); return true                          // down
      case 126: move(-1); return true                         // up
      case 123, 124: return true                              // left, right: nothing to do in a vertical list
      default: break
      }
    }
    // Any key that types a visible character joins the word: letters, digits, punctuation (iAvro inputText).
    guard let s = event.characters, !s.isEmpty,
      s.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
    else { return false }
    buffer += s
    refresh()
    return true
  }

  /// The app ends the composition (click elsewhere, switch input source): iAvro inserts the roman text as typed.
  override func commitComposition(_ sender: Any!) {
    guard !buffer.isEmpty else { return }
    client()?.insertText(buffer, replacementRange: notFound)
    reset()
  }

  override func deactivateServer(_ sender: Any!) {
    commitComposition(sender)
    lex.save()
    super.deactivateServer(sender)
  }

  // MARK: composing

  /// findCurrentCandidates + updateComposition + updateCandidatesPanel.
  private func refresh() {
    candidates = []
    prevSelected = -1
    if !buffer.isEmpty {
      let parts = Lexicon.split(buffer)
      prefix = lex.bangla.parse(parts.prefix); term = parts.term; suffix = lex.bangla.parse(parts.suffix)
      let list = lex.suggest(term)
      if list.isEmpty {
        candidates = [prefix]
      } else {
        if let prev = lex.remembered(term) { prevSelected = list.firstIndex { same($0, prev) } ?? -1 }
        candidates = list.map { prefix + $0 + suffix }
        // Emoticons typed with punctuation (`:-)`) come first. Like iAvro, the remembered row is not shifted.
        if !same(buffer, term), let smiley = lex.autocorrect(buffer) { candidates.insert(smiley, at: 0) }
      }
    }
    client()?.setMarkedText(
      NSAttributedString(string: buffer, attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]),
      selectionRange: NSRange(location: (buffer as NSString).length, length: 0), replacementRange: notFound)
    guard !candidates.isEmpty else { CandidatePanel.shared.hide(); return }
    highlight(min(max(prevSelected, 0), candidates.count - 1))
    render()
  }

  private func render() {
    var caret = NSRect.zero
    _ = client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
    let panel = CandidatePanel.shared
    panel.onPick = { [weak self] i in self?.highlight(i); self?.commit() }
    panel.show(header: buffer, items: candidates, selected: selected, caret: caret)
  }

  /// candidateSelectionChanged: iAvro remembers the highlighted row (not only the committed one) for this
  /// spelling, except the first row while nothing is remembered.
  private func highlight(_ i: Int) {
    selected = i
    let c = candidates[i]
    guard !term.isEmpty, !(same(c, candidates[0]) && prevSelected == -1) else { return }
    let s = c as NSString, p = (prefix as NSString).length, q = (suffix as NSString).length
    guard s.length >= p + q else { return }   // emoticon row: no word inside
    lex.highlight(s.substring(with: NSRange(location: p, length: s.length - p - q)), candidate: c, for: term)
  }

  private func move(_ delta: Int) {
    let i = min(max(selected + delta, 0), candidates.count - 1)   // no wrap, like the system list
    guard i != selected else { return }
    highlight(i)
    render()
  }

  /// candidateSelected: insert the highlighted row, then the space or tab that was typed.
  private func commit(_ extra: String = "") {
    guard candidates.indices.contains(selected) else { return }
    client()?.insertText(candidates[selected] + extra, replacementRange: notFound)
    reset()
    lex.save()
  }

  private func cancel() {
    client()?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
    reset()
  }

  private func reset() {
    buffer = ""; candidates = []; selected = 0; prevSelected = -1
    CandidatePanel.shared.hide()
  }
}
