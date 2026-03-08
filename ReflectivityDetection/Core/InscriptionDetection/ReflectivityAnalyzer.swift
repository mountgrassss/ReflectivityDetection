import Foundation
import CoreImage
import ARKit

class ReflectivityAnalyzer {
    // Detection mode constants
    enum DetectionMode: Int {
        case standard = 0
        case highSensitivity = 1
        case archaeological = 2
    }

    // Current detection mode
    private var detectionMode: DetectionMode = .standard

    // Shared CIContext to avoid repeated creation
    private var ciContext: CIContext

    // MARK: - Temporal Smoothing (EMA)

    // Separate history per metric for proper EMA
    private var specularHistory: [Float] = []
    private var diffuseHistory: [Float] = []
    private var varianceHistory: [Float] = []
    private var brightnessHistory: [Float] = []
    private var historyCapacity = 5

    // Surface classification hysteresis
    private var lastClassifiedType: SurfaceType = .unknown
    private var consecutiveClassificationCount: Int = 0
    private let requiredConsecutiveCount: Int = 3

    // Threshold values for detection
    private var specularThreshold: Float = 0.9
    private var diffuseThreshold: Float = 0.85

    // Calibration adjustment factors
    private var specularThresholdAdjustment: Float = 1.0
    private var diffuseThresholdAdjustment: Float = 1.0
    private var brightnessVarianceBaseline: Float = 0.01

    // Cache average brightness within a single frame
    private var cachedFrameBrightness: Float?

    // MARK: - Initialization

    init() {
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: true
        ])
        loadCalibrationValues()
    }

    /// Set a shared CIContext from the view controller
    func setCIContext(_ context: CIContext) {
        self.ciContext = context
    }

    /// Set the detection mode
    func setDetectionMode(_ mode: Int) {
        guard let newMode = DetectionMode(rawValue: mode) else {
            detectionMode = .standard
            return
        }

        if detectionMode != newMode {
            detectionMode = newMode
            applyDetectionModeSettings()
        }
    }

    // MARK: - Detection Mode Settings

    private func applyDetectionModeSettings() {
        switch detectionMode {
        case .standard:
            historyCapacity = 5
            specularThreshold = 0.9 * specularThresholdAdjustment
            diffuseThreshold = 0.85 * diffuseThresholdAdjustment

        case .highSensitivity:
            historyCapacity = 8
            specularThreshold = 0.75 * specularThresholdAdjustment
            diffuseThreshold = 0.80 * diffuseThresholdAdjustment

        case .archaeological:
            historyCapacity = 6
            specularThreshold = 0.85 * specularThresholdAdjustment
            diffuseThreshold = 0.88 * diffuseThresholdAdjustment
        }
    }

    // MARK: - Calibration

    func loadCalibrationValues() {
        let defaults = UserDefaults.standard
        let hasBeenCalibrated = defaults.bool(forKey: "ReflectivityDetection.hasBeenCalibrated")

        if hasBeenCalibrated {
            if let adjustment = defaults.object(forKey: "ReflectivityDetection.specularThresholdAdjustment") as? Float {
                specularThresholdAdjustment = adjustment
                specularThreshold *= adjustment
            }

            if let adjustment = defaults.object(forKey: "ReflectivityDetection.diffuseThresholdAdjustment") as? Float {
                diffuseThresholdAdjustment = adjustment
                diffuseThreshold *= adjustment
            }

            if let baseline = defaults.object(forKey: "ReflectivityDetection.brightnessVarianceBaseline") as? Float {
                brightnessVarianceBaseline = baseline
            }
        }
    }

    // MARK: - Frame Analysis

    /// Analyze a frame to detect reflectivity characteristics.
    /// The input image should already be at the desired resolution -
    /// no additional downsampling is applied here.
    func analyzeFrame(_ ciImage: CIImage) -> ReflectivityMetrics {
        autoreleasepool {
            // Clear per-frame cache
            cachedFrameBrightness = nil

            var metrics = ReflectivityMetrics()

            // 1. Calculate average brightness (cached for reuse)
            let rawBrightness = calculateAverageBrightness(ciImage)
            metrics.averageBrightness = smoothedValue(
                rawBrightness,
                history: &brightnessHistory
            )

            // 2. Calculate brightness variance (spatial analysis)
            let rawVariance = calculateBrightnessVariance(ciImage)
            metrics.brightnessVariance = smoothedValue(
                rawVariance,
                history: &varianceHistory
            )

            // 3. Detect specular highlights (uses cached brightness)
            let rawSpecular = detectSpecularHighlights(in: ciImage)
            metrics.specularScore = smoothedValue(
                rawSpecular,
                history: &specularHistory
            )

            // 4. Calculate diffuse reflection score
            let rawDiffuse = calculateDiffuseReflection(
                variance: rawVariance
            )
            metrics.diffuseScore = smoothedValue(
                rawDiffuse,
                history: &diffuseHistory
            )

            // 5. Classify surface with hysteresis
            metrics.surfaceType = classifySurface(metrics)

            return metrics
        }
    }

    // MARK: - Temporal Smoothing

    /// Apply EMA smoothing to a metric value using its own history.
    private func smoothedValue(
        _ currentValue: Float,
        history: inout [Float]
    ) -> Float {
        history.append(currentValue)
        if history.count > historyCapacity {
            history.removeFirst()
        }

        guard history.count > 1 else {
            return currentValue
        }

        let alpha = getAlphaForTemporalSmoothing()
        let historicalAverage = history.dropLast().reduce(0, +)
            / Float(history.count - 1)
        return alpha * currentValue + (1 - alpha) * historicalAverage
    }

    private func getAlphaForTemporalSmoothing() -> Float {
        switch detectionMode {
        case .standard:
            return 0.3
        case .highSensitivity:
            return 0.2
        case .archaeological:
            return 0.4
        }
    }

    // MARK: - Brightness Calculation

    /// Calculate the average brightness using Rec. 709 luminance.
    /// Result is cached per frame to avoid redundant computation.
    private func calculateAverageBrightness(_ image: CIImage) -> Float {
        if let cached = cachedFrameBrightness {
            return cached
        }

        let extent = image.extent
        let avgFilter = CIFilter.areaAverage()
        avgFilter.setValue(image, forKey: kCIInputImageKey)
        avgFilter.setValue(extent, forKey: "inputExtent")

        guard let output = avgFilter.outputImage else { return 0.0 }
        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        let r = Float(bitmap[0]) / 255.0
        let g = Float(bitmap[1]) / 255.0
        let b = Float(bitmap[2]) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b

        cachedFrameBrightness = luminance
        return luminance
    }

    // MARK: - Brightness Variance

    /// Calculate variance in brightness across the image using a grid
    /// of cells with proper luminance calculation.
    private func calculateBrightnessVariance(_ image: CIImage) -> Float {
        let gridSize = getGridSizeForVarianceCalculation()
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)

        guard width > 0, height > 0 else { return 0.0 }

        let cellWidth = width / gridSize
        let cellHeight = height / gridSize

        guard cellWidth > 0, cellHeight > 0 else { return 0.0 }

        var brightnessSamples: [Float] = []
        brightnessSamples.reserveCapacity(gridSize * gridSize)

        for x in 0..<gridSize {
            for y in 0..<gridSize {
                let rect = CGRect(
                    x: x * cellWidth,
                    y: y * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )

                let cellFilter = CIFilter.areaAverage()
                cellFilter.setValue(image, forKey: kCIInputImageKey)
                cellFilter.setValue(rect, forKey: "inputExtent")

                guard let output = cellFilter.outputImage else { continue }
                var bitmap = [UInt8](repeating: 0, count: 4)
                ciContext.render(
                    output,
                    toBitmap: &bitmap,
                    rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: nil
                )

                // Use proper luminance formula instead of R channel only
                let r = Float(bitmap[0]) / 255.0
                let g = Float(bitmap[1]) / 255.0
                let b = Float(bitmap[2]) / 255.0
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                brightnessSamples.append(luminance)
            }
        }

        guard !brightnessSamples.isEmpty else { return 0.0 }

        let mean = brightnessSamples.reduce(0, +)
            / Float(brightnessSamples.count)
        let variance = brightnessSamples.reduce(0) {
            $0 + ($1 - mean) * ($1 - mean)
        } / Float(brightnessSamples.count)

        return variance
    }

    private func getGridSizeForVarianceCalculation() -> Int {
        switch detectionMode {
        case .standard:
            return 3
        case .highSensitivity:
            return 4
        case .archaeological:
            return 4
        }
    }

    // MARK: - Specular Highlights

    /// Detect specular highlights using cached average brightness.
    /// Uses CIAreaAverage on the thresholded image for an exact ratio.
    private func detectSpecularHighlights(in image: CIImage) -> Float {
        let avgBrightness = calculateAverageBrightness(image)

        let baseThreshold = getSpecularBaseThreshold()
        let adaptiveThreshold = max(
            baseThreshold,
            min(0.95, avgBrightness + getSpecularAdaptiveOffset())
        )

        // Threshold filter: pixels above threshold → white, below → black
        let highlightFilter = CIFilter.colorThreshold()
        highlightFilter.setValue(image, forKey: kCIInputImageKey)
        highlightFilter.setValue(
            adaptiveThreshold,
            forKey: "inputThreshold"
        )

        guard let highlights = highlightFilter.outputImage else {
            return 0.0
        }

        // Average the black/white image — the result IS the ratio of
        // white pixels (specular highlights) directly.
        let avgFilter = CIFilter.areaAverage()
        avgFilter.setValue(highlights, forKey: kCIInputImageKey)
        avgFilter.setValue(highlights.extent, forKey: "inputExtent")

        guard let output = avgFilter.outputImage else { return 0.0 }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        // CIColorThreshold outputs white (255) or black (0).
        // The area average gives us the fraction directly.
        return Float(bitmap[0]) / 255.0
    }

    private func getSpecularBaseThreshold() -> Float {
        switch detectionMode {
        case .standard:
            return 0.70
        case .highSensitivity:
            return 0.60
        case .archaeological:
            return 0.65
        }
    }

    private func getSpecularAdaptiveOffset() -> Float {
        switch detectionMode {
        case .standard:
            return 0.10
        case .highSensitivity:
            return 0.05
        case .archaeological:
            return 0.15
        }
    }

    // MARK: - Diffuse Reflection

    /// Calculate diffuse reflection score from pre-computed variance.
    /// Avoids recomputing variance (was previously called twice per frame).
    private func calculateDiffuseReflection(variance: Float) -> Float {
        let varianceMultiplier = getDiffuseVarianceMultiplier()
        return 1.0 - min(1.0, variance * varianceMultiplier)
    }

    private func getDiffuseVarianceMultiplier() -> Float {
        switch detectionMode {
        case .standard:
            return 3.0
        case .highSensitivity:
            return 2.0
        case .archaeological:
            return 4.0
        }
    }

    // MARK: - Surface Classification

    /// Classify surface type with hysteresis to prevent flickering.
    /// Uses specular score as the primary signal:
    ///   - Any meaningful specular highlights → shiny
    ///   - Near-zero specular AND very low variance → matte
    ///   - Otherwise → unknown
    private func classifySurface(
        _ metrics: ReflectivityMetrics
    ) -> SurfaceType {
        let specularScoreThreshold = getSpecularScoreThreshold()
        let matteSpecularCeiling = specularScoreThreshold * 0.7
        let matteVarianceCeiling = getVarianceThreshold()

        let candidateType: SurfaceType
        if metrics.specularScore > specularScoreThreshold {
            // Any meaningful specular highlights → reflective surface
            candidateType = .shiny
        } else if metrics.specularScore < matteSpecularCeiling
            && metrics.brightnessVariance < matteVarianceCeiling {
            // Near-zero specular AND very uniform brightness → matte
            candidateType = .matte
        } else {
            candidateType = .unknown
        }

        // Hysteresis: require consecutive identical classifications
        if candidateType == lastClassifiedType {
            consecutiveClassificationCount += 1
        } else {
            consecutiveClassificationCount = 1
            lastClassifiedType = candidateType
        }

        if consecutiveClassificationCount >= requiredConsecutiveCount {
            return candidateType
        }

        // Not enough consecutive readings - keep previous stable type
        // On first few frames, return the candidate directly
        if specularHistory.count < requiredConsecutiveCount {
            return candidateType
        }
        return lastClassifiedType
    }

    private func getVarianceThreshold() -> Float {
        let baseThreshold = min(0.02, brightnessVarianceBaseline)

        switch detectionMode {
        case .standard:
            return baseThreshold * 1.0
        case .highSensitivity:
            return baseThreshold * 0.6
        case .archaeological:
            return baseThreshold * 1.2
        }
    }

    private func getSpecularScoreThreshold() -> Float {
        switch detectionMode {
        case .standard:
            return 0.15 * specularThresholdAdjustment
        case .highSensitivity:
            return 0.08 * specularThresholdAdjustment
        case .archaeological:
            return 0.20 * specularThresholdAdjustment
        }
    }

    func debugPrintThresholds() {
        #if DEBUG
        print("Thresholds - Mode: \(detectionMode), "
            + "Specular: \(specularThreshold), "
            + "Diffuse: \(diffuseThreshold), "
            + "SpecularScore: \(getSpecularScoreThreshold()), "
            + "Variance: \(getVarianceThreshold())")
        #endif
    }
}

// MARK: - CIFilter Extensions

extension CIFilter {
    static func areaAverage() -> CIFilter {
        return CIFilter(name: "CIAreaAverage")!
    }

    static func colorThreshold() -> CIFilter {
        return CIFilter(name: "CIColorThreshold")!
    }

    static func gaussianBlur() -> CIFilter {
        return CIFilter(name: "CIGaussianBlur")!
    }
}
