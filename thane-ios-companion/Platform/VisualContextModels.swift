import Foundation

nonisolated enum VisualContextLimits {
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static let maximumSourceDimension = 16_384
    static let maximumSourcePixels = 50_000_000
    static let maximumImageDimension = 1_024
    static let maximumSummaryBytes = 512
    static let maximumVisibleTextItems = 6
    static let maximumUncertaintyItems = 4
    static let maximumItemBytes = 160
}

nonisolated enum VisualContextAvailability: Equatable, Sendable {
    case available
    case developmentOnly
    case requiresIOS27
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case unsupportedLocale
    case imageUnderstandingUnavailable

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available:
            "On-device image analysis is available."
        case .developmentOnly:
            "Local image context is available only in development builds."
        case .requiresIOS27:
            "Local image context requires iOS 27 or later."
        case .deviceNotEligible:
            "This device does not support Apple Intelligence."
        case .appleIntelligenceDisabled:
            "Enable Apple Intelligence in iOS Settings to use local image context."
        case .modelNotReady:
            "The on-device model is not ready. Try again after its download finishes."
        case .unsupportedLocale:
            "The on-device model does not support the current app language."
        case .imageUnderstandingUnavailable:
            "The on-device model does not support this image analysis."
        }
    }
}

nonisolated struct VisualContextResult: Equatable, Sendable {
    let summary: String
    let visibleText: [String]
    let uncertainties: [String]
    let processedAt: Date
    let modelName: String
    let imageWidth: Int
    let imageHeight: Int

    func bounded(imageWidth: Int, imageHeight: Int) throws -> VisualContextResult {
        let summary = Self.bounded(summary, limit: VisualContextLimits.maximumSummaryBytes)
        guard !summary.isEmpty else { throw VisualContextError.invalidResponse }
        let text = visibleText.prefix(VisualContextLimits.maximumVisibleTextItems).compactMap {
            let value = Self.bounded($0, limit: VisualContextLimits.maximumItemBytes)
            return value.isEmpty ? nil : value
        }
        let uncertainty = uncertainties.prefix(VisualContextLimits.maximumUncertaintyItems - 1).compactMap {
            let value = Self.bounded($0, limit: VisualContextLimits.maximumItemBytes)
            return value.isEmpty ? nil : value
        }
        return VisualContextResult(
            summary: summary,
            visibleText: text,
            uncertainties: ["Generated from one image. Details and visible text may be incomplete or incorrect."]
                + uncertainty,
            processedAt: processedAt,
            modelName: Self.bounded(modelName, limit: 80),
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let nextCount = byteCount + scalar.utf8.count
            guard nextCount <= limit else { break }
            scalars.append(scalar)
            byteCount = nextCount
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum VisualContextError: LocalizedError, Equatable, Sendable {
    case disabled
    case unavailable(VisualContextAvailability)
    case imageTooLarge
    case imageDimensionsTooLarge
    case invalidImage
    case multipleImages
    case invalidResponse
    case modelRefused
    case analysisFailed

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Enable local image context before choosing an image."
        case .unavailable(let availability):
            availability.message
        case .imageTooLarge:
            "Choose an image smaller than 20 MB."
        case .imageDimensionsTooLarge:
            "Choose an image with at most 50 megapixels and no side longer than 16,384 pixels."
        case .invalidImage:
            "The selected file is not a complete, supported image."
        case .multipleImages:
            "Choose a single still image rather than an animation or multi-image file."
        case .invalidResponse:
            "The on-device model did not return a usable image description."
        case .modelRefused:
            "The on-device model could not analyze this image. Try a different image."
        case .analysisFailed:
            "Local image analysis could not finish. Try again."
        }
    }
}

@MainActor
protocol VisualContextAnalyzing: AnyObject {
    var availability: VisualContextAvailability { get }
    func analyze(imageData: Data) async throws -> VisualContextResult
}
