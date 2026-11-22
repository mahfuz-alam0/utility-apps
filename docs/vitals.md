# Vitals

CPU temperature and RAM usage in the menu bar, e.g. `52° 61%`. Swift, AppKit, no dependencies, about 200 lines in [Sources/Vitals/](../Sources/Vitals/). Updates every 2 s, uses well under 1% CPU.

`./bundle.sh vitals` builds `build/Vitals.dmg` and `.build/Vitals.app` (arm64 + x86_64, ad-hoc signed); `./bundle.sh vitals install` copies it to /Applications and launches it. `swift test --filter VitalsTests` checks the sensor filter and the memory formula.

- **Temperature**: the hottest of the Apple Silicon die sensors (`PMU tdie*`), read through IOKit's HID event API. No admin password, no helper.
- **Memory**: "Memory Used" as Activity Monitor counts it (app memory + wired + compressed) out of physical RAM.
- **Colour**: the text turns orange when macOS reports the CPU is being slowed for heat (`thermalState` serious) or memory pressure is high, red when either is critical. It follows the system's own verdict, so there is no threshold to tune. Normal temperatures under load on Apple Silicon run 80–100 °C.
- **Menu**: exact values, thermal state, memory pressure, Open Activity Monitor (to find and quit the heavy app), Launch at Login.

Known limitations:
- Intel Macs show RAM only (their temperatures live in the SMC, not read here).
- The HID temperature API is private; a future macOS may remove it, and Vitals then shows RAM only instead of crashing.
- Not verified here: how the menu-bar text looks (no screen-recording permission in the build environment).
