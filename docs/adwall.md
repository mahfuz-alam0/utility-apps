# Adwall

System-wide ad/tracker blocker for macOS: a local filtering DNS service plus a menu-bar app. Swift, no dependencies. Sources in [Sources/Adwall/](../Sources/Adwall/), one binary.

`./bundle.sh adwall` builds `build/Adwall.dmg` (drag-to-Applications installer) and `.build/Adwall.app` (arm64 + x86_64, hardened runtime, ad-hoc signed; `SIGN_ID="Developer ID Application: …"` to sign for distribution); `./bundle.sh adwall install` skips the dmg, copies the app to /Applications and launches it. Install first: the daemon restores DNS and removes itself if the app it was set up from disappears. `swift test --filter AdwallTests` runs parser, matcher, script-quoting and DNS-proxy tests.

- Menu bar → **Turn On Protection…** asks for your admin password once, then `Adwall install` (run as root) copies the binary to `/Library/Application Support/Adwall/adwalld`, installs a launch daemon, and points every network service's DNS at `127.0.0.1`. **Turn Off Protection…** restores the original DNS and removes everything.
- The same binary is the CLI: `Adwall serve | install | uninstall`; no argument starts the menu-bar app.
- Blocklists: HaGeZi Pro + StevenBlack, refreshed every 24 h (`config.json` in the support folder also sets upstreams, default DoH to 1.1.1.1 / 9.9.9.9). Menu: pause/resume, recently blocked (click to allow), Edit Allowlist / Custom Blocklist (`rules/*.txt`, picked up within 2 s).
- Not verified here: turning protection on (needs the admin prompt and changes system DNS).
