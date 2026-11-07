import AppKit

/// The items under Borno in the menu-bar input menu.
final class BornoMenu: NSObject {
  static let shared = BornoMenu()

  var menu: NSMenu {
    let m = NSMenu()
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    m.addItem(withTitle: "Borno \(version)", action: nil, keyEquivalent: "")
    m.addItem(.separator())
    add(m, "Edit Custom Words…", #selector(editWords))
    add(m, "Clear Learned Words…", #selector(clearLearned))
    m.addItem(.separator())
    add(m, "About Borno", #selector(about))
    return m
  }

  private func add(_ m: NSMenu, _ title: String, _ action: Selector) {
    m.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
  }

  /// Opens the custom words file (created with instructions on first use). Saved edits apply the next time a
  /// text field gets focus.
  @objc private func editWords() {
    let url = Lexicon.userWordsURL, fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? """
        # Your own words, one per line: names, places, slang, anything the dictionary lacks.
        # Type the word as you want it, in Bangla. Lines starting with # are ignored.
        # Save the file; Borno picks it up the next time you click into a text field.

        """.write(to: url, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(url)
  }

  @objc private func clearLearned() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Forget learned words?"
    alert.informativeText = "Borno goes back to its default suggestion order. Your custom words are kept."
    alert.addButton(withTitle: "Forget")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { Lexicon.shared.clearLearned() }
  }

  @objc private func about() {
    let credits = NSMutableAttributedString(string: "Dictionary data from Avro Keyboard (OmicronLab), used under the ")
    credits.append(NSAttributedString(string: "MPL 1.1", attributes: [.link: URL(string: "https://www.mozilla.org/MPL/1.1/")!]))
    credits.append(NSAttributedString(string: "."))
    credits.addAttributes([.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor],
                          range: NSRange(location: 0, length: credits.length))
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
  }
}
