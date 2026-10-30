import Foundation

// Adwall             menu-bar app
// Adwall serve       run the DNS filter (launchd runs the installed copy as root)
// Adwall install     install + start the launch daemon and point system DNS at it (root)
// Adwall uninstall   restore DNS and remove the daemon (root)

switch CommandLine.arguments.dropFirst().first {
case nil:
  runApp()
case "serve":
  serve()
case "install":
  do { try install() } catch { fail(error.localizedDescription) }
case "uninstall":
  uninstall()
default:
  fail("Usage: Adwall [serve | install | uninstall]")
}
