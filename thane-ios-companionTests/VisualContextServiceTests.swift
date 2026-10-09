import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ThaneIOSCompanion

@Suite("Local selected-image context")
@MainActor
struct VisualContextServiceTests {
    @Test("Disabled consent never reaches the analyzer")
    func disabled() async {
        let analyzer = FakeVisualContextAnalyzer()
        let service = VisualContextService(analyzer: analyzer)
        await service.analyze(data: Data([1, 2, 3]))
        #expect(analyzer.callCount == 0)
        #expect(service.lastError == .disabled)
        #expect(service.result == nil)
    }

    @Test("Unavailable models never receive image data", arguments: [
        VisualContextAvailability.requiresIOS27, .deviceNotEligible,
        .appleIntelligenceDisabled, .modelNotReady, .unsupportedLocale,
        .imageUnderstandingUnavailable, .developmentOnly,
    ])
    func unavailable(_ availability: VisualContextAvailability) async {
        let analyzer = FakeVisualContextAnalyzer(availability: availability)
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        await service.analyze(data: Data([1, 2, 3]))
        #expect(analyzer.callCount == 0)
        #expect(service.lastError == .unavailable(availability))
        #expect(!service.isAnalyzing)
    }

    @Test("Oversize and corrupt images fail before model inference")
    func invalidInput() async {
        let analyzer = FakeVisualContextAnalyzer()
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        await service.analyze(data: Data(count: VisualContextLimits.maximumInputBytes + 1))
        #expect(service.lastError == .imageTooLarge)
        await service.analyze(data: Data([0, 1, 2, 3]))
        #expect(service.lastError == .invalidImage)
        await service.analyze(data: Data())
        #expect(service.lastError == .invalidImage)
        #expect(analyzer.callCount == 0)
    }

    @Test("Pixel limits reject oversized source dimensions before inference")
    func dimensions() async throws {
        let analyzer = FakeVisualContextAnalyzer()
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        let image = try makeVisualContextImage(width: 16_385, height: 1)
        await service.analyze(data: image)
        #expect(service.lastError == .imageDimensionsTooLarge)
        #expect(analyzer.callCount == 0)
    }

    @Test("Source limits accept iPhone 48 MP images and reject more than 50 MP")
    func cameraDimensions() throws {
        try VisualContextPreparedImage.validateSourceDimensions(width: 8_064, height: 6_048)
        #expect(throws: VisualContextError.imageDimensionsTooLarge) {
            try VisualContextPreparedImage.validateSourceDimensions(width: 8_192, height: 6_144)
        }
        #expect(throws: VisualContextError.imageDimensionsTooLarge) {
            try VisualContextPreparedImage.validateSourceDimensions(width: Int.max, height: Int.max)
        }
    }

    @Test("Animations are not presented as complete still-image analysis")
    func animation() async throws {
        let firstData = try makeVisualContextImage(width: 16, height: 16)
        let secondData = try makeVisualContextImage(width: 16, height: 16, pixelIntensity: 0)
        let firstSource = try #require(CGImageSourceCreateWithData(firstData as CFData, nil))
        let secondSource = try #require(CGImageSourceCreateWithData(secondData as CFData, nil))
        let firstImage = try #require(CGImageSourceCreateImageAtIndex(firstSource, 0, nil))
        let secondImage = try #require(CGImageSourceCreateImageAtIndex(secondSource, 0, nil))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, 2, nil
        ))
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.15,
                kCGImagePropertyGIFUnclampedDelayTime: 0.15,
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, firstImage, frameProperties)
        CGImageDestinationAddImage(destination, secondImage, frameProperties)
        try #require(CGImageDestinationFinalize(destination))
        let animatedSource = try #require(CGImageSourceCreateWithData((output as Data) as CFData, nil))
        try #require(CGImageSourceGetCount(animatedSource) == 2)
        let analyzer = FakeVisualContextAnalyzer()
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        await service.analyze(data: output as Data)
        #expect(service.lastError == .multipleImages)
        #expect(analyzer.callCount == 0)
    }

    @Test("Downsampling applies orientation and omits source metadata")
    func preparation() async throws {
        let analyzer = FakeVisualContextAnalyzer()
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        let image = try makeVisualContextImage(width: 2_048, height: 1_024, orientation: 6)
        let originalSource = try #require(CGImageSourceCreateWithData(image as CFData, nil))
        let originalProperties = try #require(
            CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as NSDictionary?
        )
        let originalExif = try #require(originalProperties[kCGImagePropertyExifDictionary] as? NSDictionary)
        let originalTIFF = try #require(originalProperties[kCGImagePropertyTIFFDictionary] as? NSDictionary)
        let originalGPS = try #require(originalProperties[kCGImagePropertyGPSDictionary] as? NSDictionary)
        try #require(originalExif[kCGImagePropertyExifUserComment] as? String == "Private source comment")
        try #require(originalTIFF[kCGImagePropertyTIFFMake] as? String == "Private camera name")
        try #require(originalGPS[kCGImagePropertyGPSLatitude] as? Double == 41.88)
        await service.analyze(data: image)
        let data = try #require(analyzer.lastImageData)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?)
        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyTIFFDictionary] == nil)
        let result = try #require(service.result)
        #expect(result.imageWidth == 512)
        #expect(result.imageHeight == 1_024)
        #expect(result.modelName == "Fixture on-device model")
        #expect(result.processedAt == Date(timeIntervalSince1970: 123))
        #expect(!service.isAnalyzing)
    }

    @Test("Result limits and uncertainty apply to every analyzer")
    func boundedOutput() async throws {
        let analyzer = FakeVisualContextAnalyzer()
        analyzer.output = VisualContextResult(
            summary: String(repeating: "A", count: 900),
            visibleText: Array(repeating: String(repeating: "B", count: 900), count: 20),
            uncertainties: Array(repeating: String(repeating: "C", count: 900), count: 20),
            processedAt: Date(timeIntervalSince1970: 123),
            modelName: String(repeating: "D", count: 900),
            imageWidth: 900_000,
            imageHeight: 900_000
        )
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        await service.analyze(data: try makeVisualContextImage())
        let result = try #require(service.result)
        #expect(result.summary.utf8.count <= VisualContextLimits.maximumSummaryBytes)
        #expect(result.visibleText.count <= VisualContextLimits.maximumVisibleTextItems)
        #expect(result.visibleText.allSatisfy { $0.utf8.count <= VisualContextLimits.maximumItemBytes })
        #expect(result.uncertainties.count <= VisualContextLimits.maximumUncertaintyItems)
        #expect(result.uncertainties.allSatisfy { $0.utf8.count <= VisualContextLimits.maximumItemBytes })
        #expect(result.uncertainties.first?.contains("may be incomplete or incorrect") == true)
        #expect(result.modelName.utf8.count <= 80)
        #expect(result.imageWidth == 2)
        #expect(result.imageHeight == 1)
    }

    @Test("Multibyte text and a single combining grapheme obey UTF-8 byte budgets")
    func unicodeOutputBounds() async throws {
        let combining = "a" + String(repeating: "\u{0301}", count: 900)
        try #require(combining.count == 1)
        try #require(combining.utf8.count > VisualContextLimits.maximumItemBytes)
        let analyzer = FakeVisualContextAnalyzer()
        analyzer.output = VisualContextResult(
            summary: String(repeating: "🙂", count: 900),
            visibleText: [combining], uncertainties: [combining],
            processedAt: Date(), modelName: String(repeating: "🙂", count: 900),
            imageWidth: 2, imageHeight: 1
        )
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        await service.analyze(data: try makeVisualContextImage())
        let result = try #require(service.result)
        #expect(!result.summary.isEmpty)
        #expect(result.summary.utf8.count <= VisualContextLimits.maximumSummaryBytes)
        #expect(result.summary.allSatisfy { $0 == "🙂" })
        let text = try #require(result.visibleText.first)
        #expect(text.count == 1)
        #expect(text.utf8.count <= VisualContextLimits.maximumItemBytes)
        #expect(text != combining)
        #expect(result.uncertainties.allSatisfy { $0.utf8.count <= VisualContextLimits.maximumItemBytes })
        #expect(result.modelName.utf8.count <= 80)
    }

    @Test("Empty model summaries and private error details are rejected")
    func failureHandling() async throws {
        let analyzer = FakeVisualContextAnalyzer()
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        analyzer.output = VisualContextResult(
            summary: "  \n", visibleText: [], uncertainties: [],
            processedAt: Date(), modelName: "Fixture", imageWidth: 2, imageHeight: 1
        )
        await service.analyze(data: try makeVisualContextImage())
        #expect(service.result == nil)
        #expect(service.lastError == .invalidResponse)
        analyzer.failure = NSError(domain: "Private image prompt contents", code: 1)
        await service.analyze(data: try makeVisualContextImage())
        #expect(service.lastError == .analysisFailed)
        #expect(service.lastError?.errorDescription?.contains("Private image") == false)
    }

    @Test("Revoking and reenabling consent cannot publish an older completion")
    func revokedSelection() async throws {
        let analyzer = FakeVisualContextAnalyzer(suspends: true)
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        let data = try makeVisualContextImage()
        let oldTask = Task { await service.analyze(data: data) }
        try await waitForVisualContextCondition { analyzer.callCount == 1 }
        service.setEnabled(false)
        #expect(!service.isAnalyzing)
        #expect(service.result == nil)
        service.setEnabled(true)
        let newTask = Task { await service.analyze(data: data) }
        try await waitForVisualContextCondition { analyzer.callCount == 2 }
        analyzer.complete(call: 0, summary: "Old selection")
        await oldTask.value
        #expect(service.result == nil)
        #expect(service.isAnalyzing)
        analyzer.complete(call: 1, summary: "New selection")
        await newTask.value
        #expect(service.result?.summary == "New selection")
    }

    @Test("Cancel and clear prevent late results and clear all preview state", arguments: [true, false])
    func cancelledSelection(_ usesClear: Bool) async throws {
        let analyzer = FakeVisualContextAnalyzer(suspends: true)
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        let data = try makeVisualContextImage()
        let task = Task { await service.analyze(data: data) }
        try await waitForVisualContextCondition { analyzer.callCount == 1 }
        if usesClear { service.clear() } else { service.cancel() }
        #expect(!service.isAnalyzing)
        #expect(service.result == nil)
        #expect(service.lastError == nil)
        analyzer.complete(call: 0, summary: "Discard me")
        await task.value
        #expect(service.result == nil)
        #expect(service.lastError == nil)
    }

    @Test("Caller cancellation discards output even when inference ignores cancellation")
    func callerCancellation() async throws {
        let analyzer = FakeVisualContextAnalyzer(suspends: true)
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        let data = try makeVisualContextImage()
        let task = Task { await service.analyze(data: data) }
        try await waitForVisualContextCondition { analyzer.callCount == 1 }
        task.cancel()
        analyzer.complete(call: 0, summary: "Discard me")
        await task.value
        #expect(service.result == nil)
        #expect(service.lastError == nil)
        #expect(!service.isAnalyzing)
    }

    @Test("Availability changes during analysis discard its result")
    func unavailableAtCompletion() async throws {
        let analyzer = FakeVisualContextAnalyzer(suspends: true)
        let service = VisualContextService(analyzer: analyzer, enabled: true)
        let data = try makeVisualContextImage()
        let task = Task { await service.analyze(data: data) }
        try await waitForVisualContextCondition { analyzer.callCount == 1 }
        analyzer.availability = .appleIntelligenceDisabled
        analyzer.complete(call: 0, summary: "Discard me")
        await task.value
        #expect(service.result == nil)
        #expect(service.lastError == .unavailable(.appleIntelligenceDisabled))
        #expect(!service.isAnalyzing)
    }
}

@MainActor
private final class FakeVisualContextAnalyzer: VisualContextAnalyzing {
    var availability: VisualContextAvailability
    var output = VisualContextResult(
        summary: "A red rectangle is visible.", visibleText: [], uncertainties: [],
        processedAt: Date(timeIntervalSince1970: 123),
        modelName: "Fixture on-device model", imageWidth: 2, imageHeight: 1
    )
    var failure: Error?
    private(set) var callCount = 0
    private(set) var lastImageData: Data?
    private var pending: [Int: CheckedContinuation<VisualContextResult, Error>] = [:]
    private let suspends: Bool

    init(availability: VisualContextAvailability = .available, suspends: Bool = false) {
        self.availability = availability
        self.suspends = suspends
    }

    func analyze(imageData: Data) async throws -> VisualContextResult {
        let call = callCount
        callCount += 1
        lastImageData = imageData
        if let failure { throw failure }
        if suspends {
            return try await withCheckedThrowingContinuation { pending[call] = $0 }
        }
        return output
    }

    func complete(call: Int, summary: String) {
        pending.removeValue(forKey: call)?.resume(returning: VisualContextResult(
            summary: summary, visibleText: [], uncertainties: [], processedAt: Date(),
            modelName: "Fixture", imageWidth: 2, imageHeight: 1
        ))
    }
}

private nonisolated func makeVisualContextImage(
    width: Int = 2,
    height: Int = 1,
    orientation: Int = 1,
    pixelIntensity: UInt8 = 255
) throws -> Data {
    var pixelData = Data(repeating: pixelIntensity, count: width * height * 4)
    if pixelIntensity != 255 {
        pixelData.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for offset in stride(from: 3, to: bytes.count, by: 4) {
                bytes[offset] = 255
            }
        }
    }
    let provider = try #require(CGDataProvider(data: pixelData as CFData))
    let image = try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private source comment"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Private camera name"],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 41.88,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 87.63,
            kCGImagePropertyGPSLongitudeRef: "W",
        ],
    ] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    return output as Data
}

@MainActor
private func waitForVisualContextCondition(_ condition: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<1_000 where !condition() {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
}
