import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Reads only the selected transfer file, with a bound before and during allocation.
nonisolated struct VisualContextImageSelection: Transferable, Sendable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try Self.read(from: received.file)
        }
    }

    static func read(from url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size > 0 else { throw VisualContextSelectionError.unreadable }
        guard size <= VisualContextLimits.maximumInputBytes else {
            throw VisualContextSelectionError.tooLarge
        }

        let file = try FileHandle(forReadingFrom: url)
        let data: Data
        do {
            var selectedData = Data()
            while selectedData.count <= VisualContextLimits.maximumInputBytes {
                let chunkSize = min(64 * 1024, VisualContextLimits.maximumInputBytes + 1 - selectedData.count)
                guard let chunk = try file.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                selectedData.append(chunk)
                guard selectedData.count <= VisualContextLimits.maximumInputBytes else {
                    throw VisualContextSelectionError.tooLarge
                }
            }
            guard !selectedData.isEmpty else { throw VisualContextSelectionError.unreadable }
            data = selectedData
        } catch {
            do {
                try file.close()
            } catch {
                throw VisualContextSelectionError.unreadable
            }
            throw error
        }
        try file.close()
        return Self(data: data)
    }
}

nonisolated enum VisualContextSelectionError: LocalizedError {
    case unreadable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable: "This image could not be opened. Choose another image."
        case .tooLarge: "Choose an image smaller than 20 MB."
        }
    }
}
