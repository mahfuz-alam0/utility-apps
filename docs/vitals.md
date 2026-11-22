# Vitals

Menu-bar system monitor. The menu bar shows what you pick (CPU temperature, CPU load, memory pressure, battery, network), each as a number, a small gauge, or both, e.g. `52° 47%`. Click it for a popup: an overall verdict, a card per vital with a live 5-minute trace, and a detail page behind each card. Swift, AppKit + SwiftUI, no dependencies, in [Sources/Vitals/](../Sources/Vitals/). Samples every 2 s; idles at about 0.4 % of one core and 14 MB.

`./bundle.sh vitals` builds `build/Vitals.dmg` and `.build/Vitals.app` (arm64 + x86_64, ad-hoc signed); `./bundle.sh vitals install` copies it to /Applications and launches it. `swift test --filter VitalsTests` covers the sensor math, the menu-bar display modes, alert colours and saved preferences.

## What it reads

One sampler feeds both the menu bar and the popup, so nothing is read twice.

- **CPU temperature**: the hottest Apple Silicon die sensor (`PMU tdie*`), through IOKit's HID event API. No admin password, no helper.
- **CPU load**: kernel tick counters (`host_statistics`), split into user and system.
- **Memory pressure**: `100 − kern.memorystatus_level`, the share of RAM the kernel can't hand out without compressing or swapping. "Used" is Activity Monitor's figure (app + wired + compressed); swap comes from `vm.swapusage`.
- **Battery**: the public power-sources API. macOS pushes changes, so the battery is never polled. Health and cycle count come from the battery controller (IORegistry) and are read only when you open the battery page.
- **Network**: byte counters of the `en*` interfaces (Wi-Fi, Ethernet, USB tethering). VPN tunnels are skipped so VPN traffic isn't counted twice.

## Popup

- **Overview**: verdict ("All vitals normal", "Running hot", "Memory is tight", "Battery low"), then CPU, Memory, Battery and Network cards. The footer opens Activity Monitor (to find the heavy app) or Settings.
- **Details** (click a card): CPU temperature ring, thermal state, 5-minute temperature and load charts, user/system split. Memory pressure ring, apps/wired/compressed/free breakdown, swap, pressure chart. Battery charge, time left or to full, health, cycles, capacity. Network speeds and a 5-minute up/down chart with peaks.
- **Settings**: Off / Value / Gauge / Both per metric. The menu bar updates on click, and choices persist. Also Launch at login and Quit.
- Esc goes back a page, then closes. A click anywhere else closes it. It never takes focus from the app you were in.

## Colour

The menu bar turns orange or red only when macOS itself reports trouble for a metric on screen: CPU slowed for heat (`thermalState` serious or critical), memory pressure warning or critical, or battery at 10 % / 5 % while unplugged. It follows the system's verdict, so there is no threshold to tune. Normal temperatures under load on Apple Silicon run 80–100 °C.

## Known limitations

- Intel Macs get no temperature (it lives in the SMC, which Vitals doesn't read). The temperature item drops out and the CPU card shows load.
- The HID temperature API is private. A future macOS may remove it, and Vitals then shows the other metrics instead of crashing.
- No battery temperature: current macOS doesn't expose it in the battery registry.
- Wi-Fi network name needs Location permission, so Vitals doesn't show it.
