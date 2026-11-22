import Foundation

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

struct Memory {
  let used: UInt64
  let total: UInt64
  var percent: Int { total == 0 ? 0 : Int((Double(used) / Double(total) * 100).rounded()) }

  private static let host = mach_host_self()

  /// "Memory Used" as Activity Monitor shows it: app memory + wired + compressed.
  static func current() -> Memory? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Memory(used: stats.usedPages * UInt64(getpagesize()), total: ProcessInfo.processInfo.physicalMemory)
  }
}

extension vm_statistics64 {
  var usedPages: UInt64 {
    let app = UInt64(internal_page_count) - min(UInt64(purgeable_count), UInt64(internal_page_count))
    return app + UInt64(wire_count) + UInt64(compressor_page_count)
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
}
