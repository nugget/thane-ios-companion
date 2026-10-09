import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Selected image transfer bounds")
struct VisualContextImageSelectionTests {
    @Test("Empty and oversized files are rejected before loading")
    func rejectsInvalidFileSizes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        #expect(throws: VisualContextSelectionError.self) {
            try VisualContextImageSelection.read(from: url)
        }

        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(VisualContextLimits.maximumInputBytes + 1))
        try file.close()
        #expect(throws: VisualContextSelectionError.self) {
            try VisualContextImageSelection.read(from: url)
        }
    }

    @Test("Selected bytes are read without copying a source identifier")
    func readsSelectedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(repeating: 17, count: 128 * 1024 + 1)
        try data.write(to: url)
        #expect(try VisualContextImageSelection.read(from: url).data == data)
    }
}
