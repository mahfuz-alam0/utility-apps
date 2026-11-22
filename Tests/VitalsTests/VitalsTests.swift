import AppKit
import Testing

@testable import Vitals

@Test func hottestIgnoresJunkReadings() {
  #expect(hottest([33.4, -22.1, 51.8, 0, 200]) == 51.8)
  #expect(hottest([-22]) == nil)
  #expect(hottest([]) == nil)
}

@Test func usedMemoryIsAppPlusWiredPlusCompressed() {
  var stats = vm_statistics64()
  stats.internal_page_count = 100
  stats.purgeable_count = 10
  stats.wire_count = 20
  stats.compressor_page_count = 5
  stats.free_count = 999  // free and file cache do not count as used
  stats.external_page_count = 999
  let memory = Memory(stats: stats, pageSize: 1, total: 200)
  #expect(memory.used == 115)
  #expect(memory.free == 85)
  #expect(Memory(app: 8, total: 16).percent == 50)
  #expect(Memory(app: 1, total: 0).percent == 0)
}

@Test func cpuLoadFromTickDeltas() {
  #expect(CPULoad(ticks: [30, 20, 40, 10]) == CPULoad(user: 0.4, system: 0.2))  // nice counts as user
  #expect(CPULoad(ticks: [0, 0, 0, 0]) == nil)
}

@Test func networkDeltaSurvivesCounterWrapAndUnplug() {
  let before = ["en0": Counters(rx: UInt32.max - 9, tx: 100), "en5": Counters(rx: 1, tx: 1)]
  let after = ["en0": Counters(rx: 10, tx: 150), "en6": Counters(rx: 999, tx: 999)]  // en5 unplugged, en6 new
  let bytes = moved(from: before, to: after)
  #expect(bytes.rx == 20)
  #expect(bytes.tx == 50)
}

@Test func batteryHealthReadsBothRegistryLayouts() {
  // recent Apple Silicon: mAh nested in BatteryData, top-level MaxCapacity is a percentage
  let nested = Battery.Health(registry: [
    "CycleCount": 52, "MaxCapacity": 100, "BatteryData": ["AppleRawMaxCapacity": 4538, "DesignCapacity": 4629],
  ])
  #expect(nested == Battery.Health(cycles: 52, capacity: 4538, design: 4629))
  #expect(nested.percent == 98)
  #expect(Battery.Health(registry: ["CycleCount": 300, "MaxCapacity": 5000, "DesignCapacity": 6000]).percent == 83)  // Intel
  #expect(Battery.Health(registry: ["MaxCapacity": 100, "DesignCapacity": 4629]).percent == nil)  // never 100 mAh
}

@Test func formatting() {
  #expect(speed(0) == "0 KB/s")
  #expect(speed(340_000) == "340 KB/s")
  #expect(speed(999_600) == "1.0 MB/s")
  #expect(speed(1_234_000) == "1.2 MB/s")
  #expect(speed(150_000_000) == "150 MB/s")
  #expect(speed(2_500_000_000) == "2.5 GB/s")
  #expect(duration(minutes: 80) == "1h 20m")
  #expect(duration(minutes: 45) == "45m")
  #expect(uptime(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 3 * 86400 + 4 * 3600 + 59)) == "3d 4h")
  #expect(uptime(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 5 * 3600 + 12 * 60)) == "5h 12m")
}

@Test func menuBarFollowsDisplayModes() {
  var s = Sample()
  s.temperature = 48.4
  s.pressurePercent = 47
  s.battery = Battery(percent: 80, plugged: true)
  s.network = NetRate(up: 0, down: 5000)
  let parts = MenuBar.parts(s, [.temperature: .value, .load: .off, .memory: .gauge, .battery: .both, .network: .value])
  #expect(parts.count == 3)
  #expect(parts[0] == Part(lines: ["48°"], reserve: "88°", under: [Part.Bar(fill: 0.45)]))  // memory bar (47 % in 5 % steps) under the temperature
  #expect(parts[1] == Part(gauge: .battery(0.8, symbol: "powerplug.fill"), lines: ["80%"], reserve: "88%"))  // plugged in: never tinted
  #expect(parts[2].gauge == nil && parts[2].lines == ["↑ 0 KB/s", "↓ 5 KB/s"])
  #expect(MenuBar.parts(s, [.memory: .gauge]) == [Part(gauge: .bar(0.45))])  // no temperature: a bar of its own
  #expect(MenuBar.tempHeat(50) == 0 && MenuBar.tempHeat(65) == 0.5 && MenuBar.tempHeat(80) == 1)
  #expect(MenuBar.memoryHeat(47) == 0 && MenuBar.memoryHeat(70) == 0.5 && MenuBar.loadHeat(0.9) == 0.75)
  s.load = CPULoad(user: 0.6, system: 0.2)
  #expect(MenuBar.parts(s, [.temperature: .value, .load: .gauge, .memory: .gauge])
    == [Part(lines: ["48°"], reserve: "88°", under: [Part.Bar(fill: 0.8, heat: 0.5), Part.Bar(fill: 0.45)])])  // load bar on top
  #expect(MenuBar.parts(s, [.network: .both])[0].lines == ["0 KB/s", "5 KB/s"])  // gauge draws the arrows
  #expect(MenuBar.parts(s, [:]).isEmpty)
  s.temperature = nil  // e.g. Intel: the metric drops out instead of showing a blank
  #expect(MenuBar.parts(s, [.temperature: .both]).isEmpty)
  #expect(MenuBar.image(parts).isTemplate)  // all normal: plain system look
  #expect(!MenuBar.image([Part(lines: ["85°"], heat: 0.65)]).isTemplate)
  #expect(!MenuBar.image([Part(lines: ["50°"], under: [Part.Bar(fill: 0.9, heat: 0.5)])]).isTemplate)
  #expect(MenuBar.tempHeat(51) < 0.1 && MenuBar.tempHeat(55) < MenuBar.tempHeat(60))  // creeps in, no jump at one reading
}

@Test func lowBatteryTintsOnlyItsOwnReading() {
  var s = Sample()
  #expect(s.health.headline == "All vitals normal")
  s.pressure = .warning
  s.thermal = .critical
  #expect(s.health.headline == "Overheating")
  s.battery = Battery(percent: 4)
  #expect(MenuBar.parts(s, [.battery: .value])[0].heat == 1)
  s.battery?.percent = 10
  #expect(MenuBar.parts(s, [.battery: .value])[0].heat == 0.5)
  s.battery?.percent = 13
  #expect(MenuBar.parts(s, [.battery: .value])[0].heat == 0.2)  // creeps in before 10 %, no jump
  s.battery?.plugged = true
  #expect(MenuBar.parts(s, [.battery: .value])[0].heat == 0)
}

@Test @MainActor func prefsPersist() {
  let name = "vitals-test-\(UUID())"
  let store = UserDefaults(suiteName: name)!
  defer { store.removePersistentDomain(forName: name) }
  let first = Prefs(store: store)
  #expect(first[.temperature] == .value && first[.memory] == .gauge && first[.network] == .off)
  first[.network] = .both
  first[.temperature] = .off
  let second = Prefs(store: store)
  #expect(second[.network] == .both && second[.temperature] == .off && second[.memory] == .gauge)
}

@Test func sensorsReadOnThisMac() {
  #expect(Memory.current() != nil)
  #expect(Pressure.percent().map { (0...100).contains($0) } == true)
  #expect(bootDate != nil)
  let cpu = CPUMeter()
  let net = NetMeter()
  #expect(cpu.read() == nil && net.read() == nil)  // a rate needs two readings
  usleep(100_000)
  #expect(cpu.read() != nil)
  #expect(net.read() != nil)
  #if arch(arm64)
    if let temp = Thermometer()?.read() { #expect((1..<150).contains(temp)) }
  #endif
}
