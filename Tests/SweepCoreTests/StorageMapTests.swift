import Foundation
import Testing
@testable import SweepCore

struct StorageMapTests {
    @Test func systemVolumeIsMeasuredPerVolumeNotWholeDisk() {
        let volumes = StorageMap.systemVolumes()
        guard let system = volumes["System"], let disk = SystemInfo.disk() else { return }
        #expect(system > 1_000_000_000)
        #expect(system < disk.used / 2)
        #expect(volumes["Data"] ?? 0 > system)
    }

    @Test func adaptiveMeasureMatchesWholeMeasure() async {
        let fx = Fixture()
        for index in 0..<30 { fx.file("big/part\(index % 3)/file\(index).bin", bytes: 4_096) }
        fx.file("big/loose.bin", bytes: 8_192)
        let whole = DirectorySizer.size(of: fx.path("big"))

        var parts: [String: SizeInfo] = [:]
        let adaptive = StorageMap.measureAdaptive(fx.path("big"), reuse: nil, depth: 0, parts: &parts)
        #expect(adaptive.allocated == whole.allocated)
        #expect(adaptive.fileCount == whole.fileCount)
        #expect(parts[fx.path("big")] != nil)
    }

    @Test func simulatorRuntimeMountsAreNotCountedInLibrary() {
        let layout = StorageMap.layout(home: Fixture().root)
        let library = layout.first { $0.kind == .systemLibrary }?.paths ?? []
        #expect(!library.contains { $0.hasPrefix("/Library/Developer/CoreSimulator/Volumes") })
    }
}
