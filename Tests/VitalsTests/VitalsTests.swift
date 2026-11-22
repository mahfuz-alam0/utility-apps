import Darwin
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
  #expect(stats.usedPages == 115)
  #expect(Memory(used: 8, total: 16).percent == 50)
  #expect(Memory(used: 1, total: 0).percent == 0)
}

@Test func sensorsReadOnThisMac() {
  #expect(Memory.current() != nil)
  #if arch(arm64)
    if let temp = Thermometer()?.read() { #expect((1..<150).contains(temp)) }
  #endif
}
