import Foundation
import IOKit.ps

/// CPU die temperature from the Apple Silicon PMU sensors, read through IOKit's private HID event API (no root needed).
/// The functions are looked up at runtime, so a macOS that drops them gives nil instead of a crash at launch.
/// ponytail: Apple Silicon only ("PMU tdie*" sensors); Intel Macs would need the SMC (key TC0P) and get no temperature.
final class Thermometer {
  private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
  private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double
  private let temperatureEvent: Int64 = 15  // kIOHIDEventTypeTemperature
  private let client: AnyObject
  private let sensors: [AnyObject]
  private let copyEvent: CopyEvent
  private let floatValue: FloatValue

  init?() {
    typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<CFTypeRef>?
    guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
      let create = dlsym(iokit, "IOHIDEventSystemClientCreate"),
      let setMatching = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
      let copyServices = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
      let copyProperty = dlsym(iokit, "IOHIDServiceClientCopyProperty"),
      let copyEvent = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
      let floatValue = dlsym(iokit, "IOHIDEventGetFloatValue"),
      let client = unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
    else { return nil }
    // usage page 0xff00, usage 5: Apple vendor temperature sensors
    unsafeBitCast(setMatching, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    let services = unsafeBitCast(copyServices, to: CopyServices.self)(client)?.takeRetainedValue() as? [AnyObject] ?? []
    let product = unsafeBitCast(copyProperty, to: CopyProperty.self)
    sensors = services.filter { (product($0, "Product" as CFString)?.takeRetainedValue() as? String)?.contains("tdie") == true }
    guard !sensors.isEmpty else { return nil }
    self.client = client
    self.copyEvent = unsafeBitCast(copyEvent, to: CopyEvent.self)
    self.floatValue = unsafeBitCast(floatValue, to: FloatValue.self)
  }

  /// Hottest die sensor in °C.
  func read() -> Double? {
    hottest(sensors.compactMap { sensor in
      copyEvent(sensor, temperatureEvent, 0, 0).map { floatValue($0.takeRetainedValue(), Int32(temperatureEvent << 16)) }
    })
  }
}

/// Max of the plausible readings; idle sensors report junk such as -22 °C.
func hottest(_ readings: [Double]) -> Double? { readings.filter { (1..<150).contains($0) }.max() }

private let host = mach_host_self()

/// Share of all cores busy since the previous reading, from the kernel's tick counters. First call returns nil.
final class CPUMeter {
  private var last: [UInt32]?

  func read() -> CPULoad? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return nil }
    let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    defer { last = ticks }
    return last.flatMap { CPULoad(ticks: zip(ticks, $0).map { $0 &- $1 }) }
  }
}

struct CPULoad: Equatable {
  var user = 0.0, system = 0.0  // 0...1
  var total: Double { user + system }
}

extension CPULoad {
  /// Tick deltas in host_cpu_load_info order: user, system, idle, nice. Nice counts as user, as in Activity Monitor.
  init?(ticks d: [UInt32]) {
    let all = Double(d.reduce(UInt64(0)) { $0 + UInt64($1) })
    guard d.count == 4, all > 0 else { return nil }
    self.init(user: (Double(d[0]) + Double(d[3])) / all, system: Double(d[1]) / all)
  }
}

struct Memory: Equatable {
  var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0
  var total: UInt64
  /// "Memory Used" as Activity Monitor shows it: app memory + wired + compressed.
  var used: UInt64 { app + wired + compressed }
  var free: UInt64 { total > used ? total - used : 0 }
  var percent: Int { total == 0 ? 0 : Int((Double(used) / Double(total) * 100).rounded()) }

  static func current() -> Memory? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Memory(stats: stats, pageSize: UInt64(getpagesize()), total: ProcessInfo.processInfo.physicalMemory)
  }

  static func swapUsed() -> UInt64? {
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    return sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 ? swap.xsu_used : nil
  }
}

extension Memory {
  init(stats s: vm_statistics64, pageSize: UInt64, total: UInt64) {
    let app = UInt64(s.internal_page_count) - min(UInt64(s.purgeable_count), UInt64(s.internal_page_count))
    self.init(app: app * pageSize, wired: UInt64(s.wire_count) * pageSize, compressed: UInt64(s.compressor_page_count) * pageSize, total: total)
  }
}

enum Pressure: Int32 {
  case normal = 1, warning = 2, critical = 4

  /// The kernel's own verdict, the same signal as Activity Monitor's memory pressure graph.
  static func current() -> Pressure {
    var level: Int32 = 1
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
    return Pressure(rawValue: level) ?? .normal
  }

  /// 0–100: the share of RAM the kernel can't hand out without compressing or swapping (100 − its "% available").
  static func percent() -> Int? {
    var level: Int32 = -1
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, (0...100).contains(level) else { return nil }
    return 100 - Int(level)
  }
}

struct Battery: Equatable {
  var percent: Int
  var plugged = false
  var charging = false
  var charged = false
  var minutes: Int?  // until empty on battery, until full while charging; nil while macOS is still estimating

  /// The internal battery from the public power-sources API; nil on desktops.
  static func current() -> Battery? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for source in list {
      guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
        d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
        let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
      else { continue }
      let charging = d[kIOPSIsChargingKey] as? Bool ?? false
      let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
      return Battery(
        percent: Int((Double(now) / Double(max) * 100).rounded()),
        plugged: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
        charging: charging, charged: d[kIOPSIsChargedKey] as? Bool ?? false,
        minutes: minutes.flatMap { $0 > 0 ? $0 : nil })
    }
    return nil
  }

  struct Health: Equatable {
    var cycles: Int?
    var capacity: Int?  // mAh now
    var design: Int?  // mAh when new
    var percent: Int? {
      guard let capacity, let design, design > 0 else { return nil }
      return min(100, capacity * 100 / design)
    }
  }

  /// Wear figures from the battery controller. They change over months, so read on demand, not per tick.
  static func health() -> Health? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
      let registry = properties?.takeRetainedValue() as? [String: Any]
    else { return nil }
    return Health(registry: registry)
  }
}

extension Battery.Health {
  /// Recent macOS keeps the mAh figures inside "BatteryData"; older releases put them at the top level.
  /// Apple Silicon's top-level MaxCapacity is a percentage (100), so it only counts when it can't be one (Intel: mAh).
  init(registry: [String: Any]) {
    let nested = registry["BatteryData"] as? [String: Any] ?? [:]
    func int(_ key: String) -> Int? { registry[key] as? Int ?? nested[key] as? Int }
    self.init(cycles: int("CycleCount"), capacity: int("AppleRawMaxCapacity") ?? int("MaxCapacity").flatMap { $0 > 100 ? $0 : nil },
              design: int("DesignCapacity"))
  }
}

struct NetRate: Equatable {
  var up = 0.0, down = 0.0  // bytes per second
}

struct Counters: Equatable {
  var rx: UInt32, tx: UInt32
}

/// Bytes moved between two readings, over interfaces present in both. The kernel's per-interface counters are
/// 32-bit and wrap at 4 GB, so the subtraction wraps too; an interface that vanished is skipped, not read as negative.
func moved(from old: [String: Counters], to new: [String: Counters]) -> (rx: UInt64, tx: UInt64) {
  new.reduce(into: (rx: UInt64(0), tx: UInt64(0))) { sum, entry in
    guard let before = old[entry.key] else { return }
    sum.rx += UInt64(entry.value.rx &- before.rx)
    sum.tx += UInt64(entry.value.tx &- before.tx)
  }
}

/// Upload/download speed over the en* interfaces (Wi-Fi, Ethernet, USB tethering). First call returns nil.
/// ponytail: utun* is skipped so VPN traffic isn't counted twice; traffic on bridge/other virtual interfaces isn't shown.
final class NetMeter {
  private var last: [String: Counters] = [:]
  private var lastTime = 0.0

  func read() -> NetRate? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var now: [String: Counters] = [:]
    var next = list
    while let entry = next?.pointee {
      next = entry.ifa_next
      guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else { continue }
      let name = String(cString: entry.ifa_name)
      guard name.hasPrefix("en") else { continue }
      let stats = data.assumingMemoryBound(to: if_data.self).pointee
      now[name] = Counters(rx: stats.ifi_ibytes, tx: stats.ifi_obytes)
    }
    let time = ProcessInfo.processInfo.systemUptime
    defer { (last, lastTime) = (now, time) }
    guard lastTime > 0, time > lastTime else { return nil }
    let bytes = moved(from: last, to: now)
    return NetRate(up: Double(bytes.tx) / (time - lastTime), down: Double(bytes.rx) / (time - lastTime))
  }
}

/// Boot time including sleep (kern.boottime), unlike ProcessInfo.systemUptime.
let bootDate: Date? = {
  var time = timeval()
  var size = MemoryLayout<timeval>.size
  return sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 ? Date(timeIntervalSince1970: TimeInterval(time.tv_sec)) : nil
}()

func sysctlString(_ name: String) -> String? {
  var size = 0
  guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
  return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
