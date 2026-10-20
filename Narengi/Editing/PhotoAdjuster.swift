import CoreGraphics
import CoreImage
import Foundation

/// Edit Photo's sliders, each −100…100 (0 = unchanged); Sharpness and Vignette run 0…100.
struct Adjustments: Equatable, Sendable {
    enum Key: String, CaseIterable, Identifiable {
        case exposure, contrast, shadows, saturation, warmth, sharpness, vignette
        var id: String { rawValue }

        var title: String {
            switch self {
            case .exposure: return "Exposure"
            case .contrast: return "Contrast"
            case .shadows: return "Shadows"
            case .saturation: return "Saturation"
            case .warmth: return "Warmth"
            case .sharpness: return "Sharpness"
            case .vignette: return "Vignette"
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .sharpness, .vignette: return 0...100
            default: return -100...100
            }
        }

        var group: String {
            switch self {
            case .exposure, .contrast, .shadows: return "Light"
            case .saturation, .warmth: return "Colour"
            case .sharpness: return "Detail"
            case .vignette: return "Effects"
            }
        }
    }

    private(set) var values: [Key: Double] = [:]

    subscript(key: Key) -> Double {
        get { values[key] ?? 0 }
        set { values[key] = newValue == 0 ? nil : min(max(newValue, key.range.lowerBound), key.range.upperBound) }
    }

    var isIdentity: Bool { values.isEmpty }
}

/// Edit Photo's CoreImage pipeline. The filters (exposure, colour controls, shadow lift, white-point warmth,
/// luminance sharpening, vignette) are standard CoreImage; the slider-to-parameter mappings are Narengi's own.
enum PhotoAdjuster {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func apply(_ adjustments: Adjustments, to image: CGImage) throws -> CGImage {
        guard !adjustments.isIdentity else { return image }
        let source = CIImage(cgImage: image)
        let extent = source.extent
        var ci = source
        func v(_ key: Adjustments.Key) -> Double { adjustments[key] / 100 }

        if v(.exposure) != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v(.exposure) * 2])
        }
        if v(.shadows) != 0 {
            ci = ci.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": v(.shadows), "inputHighlightAmount": 1.0])
        }
        if v(.contrast) != 0 || v(.saturation) != 0 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: max(1 + v(.contrast) * 0.5, 0.25),
                kCIInputSaturationKey: max(1 + v(.saturation), 0),
            ])
        }
        if v(.warmth) != 0 {
            // Lowering the target white point warms the picture.
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - v(.warmth) * 3000, y: 0),
            ])
        }
        if v(.sharpness) > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: v(.sharpness) * 1.5])
        }
        if v(.vignette) > 0 {
            ci = ci.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: v(.vignette) * 1.6, kCIInputRadiusKey: 2.0])
        }
        guard let result = context.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: ImageOps.sRGB) else {
            throw ConversionError.encodeFailed("image")
        }
        return result
    }
}
