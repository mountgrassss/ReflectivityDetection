import Foundation
import CoreImage
import Vision
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
    
    // History of brightness values for temporal analysis
    private var brightnessHistory: [Float] = []
    private var historyCapacity = 5 // Reduced from 10 to save memory
    
    // Enhanced performance tracking
    private var lastOperationTimes: [String: TimeInterval] = [:]
    private var operationTimeHistory: [String: [TimeInterval]] = [:]
    private let maxTimeHistoryEntries = 10 // Reduced from 20 to save memory
    
    // Memory management
    private var pixelBufferPool: CVPixelBufferPool?
    
    // Threshold values for detection
    private var specularThreshold: Float = 0.9
    private var diffuseThreshold: Float = 0.6
    
    // Calibration adjustment factors
    private var specularThresholdAdjustment: Float = 1.0
    private var diffuseThresholdAdjustment: Float = 1.0
    private var brightnessVarianceBaseline: Float = 0.01
    
    // MARK: - Public Methods
    
    init() {
        // Initialize with default context
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false,
                                            .cacheIntermediates: true])
        loadCalibrationValues()
    }
    
    /// Set a shared CIContext from the view controller
    func setCIContext(_ context: CIContext) {
        self.ciContext = context
    }
    
    /// Set the detection mode
    /// - Parameter mode: The detection mode (0: Standard, 1: High Sensitivity, 2: Archaeological)
    func setDetectionMode(_ mode: Int) {
        guard let newMode = DetectionMode(rawValue: mode) else {
            print("Invalid detection mode: \(mode), using standard mode")
            detectionMode = .standard
            return
        }
        
        if detectionMode != newMode {
            detectionMode = newMode
            print("Detection mode set to: \(detectionMode)")
            
            // Adjust parameters based on detection mode
            applyDetectionModeSettings()
        }
    }
    
    /// Apply settings specific to the current detection mode
    private func applyDetectionModeSettings() {
        switch detectionMode {
        case .standard:
            // Standard mode: Balanced performance for most artifacts
            historyCapacity = 5
            specularThreshold = 0.9 * specularThresholdAdjustment
            diffuseThreshold = 0.6 * diffuseThresholdAdjustment
            
        case .highSensitivity:
            // High Sensitivity mode: Optimized for very faint inscriptions
            historyCapacity = 8 // More temporal smoothing for stability
            specularThreshold = 0.75 * specularThresholdAdjustment // Lower threshold to detect fainter highlights
            diffuseThreshold = 0.5 * diffuseThresholdAdjustment // More sensitive to diffuse surfaces
            
        case .archaeological:
            // Archaeological mode: Tuned for ancient stone and ceramic artifacts
            historyCapacity = 6
            specularThreshold = 0.85 * specularThresholdAdjustment
            diffuseThreshold = 0.65 * diffuseThresholdAdjustment // Higher threshold for ancient materials
        }
    }
    
    /// Loads calibration values from UserDefaults if available
    func loadCalibrationValues() {
        let defaults = UserDefaults.standard
        let hasBeenCalibrated = defaults.bool(forKey: "ReflectivityDetection.hasBeenCalibrated")
        
        if hasBeenCalibrated {
            // Load calibration adjustments
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
            
            print("Loaded calibration values - Specular Adj: \(specularThresholdAdjustment), Diffuse Adj: \(diffuseThresholdAdjustment)")
        } else {
            print("No calibration values found, using defaults")
        }
    }
    
    /// Analyze a frame to detect reflectivity characteristics
    /// - Parameter ciImage: The CIImage from the AR frame
    /// - Returns: ReflectivityMetrics containing analysis results
    func analyzeFrame(_ ciImage: CIImage) -> ReflectivityMetrics {
        autoreleasepool {
            var metrics = ReflectivityMetrics()
            
            // Start overall timing
            let startTime = CACurrentMediaTime()
            
            // Determine downsampling scale based on detection mode
            let downsamplingScale = getDownsamplingScale()
            
            // Downsample the image once for all operations
            let downsampledImage = downsampleImage(ciImage, scale: downsamplingScale)
            trackTime("downsample", startTime: startTime)
            
            // Calculate average brightness
            let t1 = CACurrentMediaTime()
            metrics.averageBrightness = calculateAverageBrightness(downsampledImage)
            trackTime("averageBrightness", startTime: t1)
            
            // Add to history for temporal analysis
            let t2 = CACurrentMediaTime()
            updateBrightnessHistory(metrics.averageBrightness)
            trackTime("updateHistory", startTime: t2)
            
            // Calculate brightness variance (spatial analysis)
            let t3 = CACurrentMediaTime()
            metrics.brightnessVariance = calculateBrightnessVariance(downsampledImage)
            trackTime("brightnessVariance", startTime: t3)
            
            // Detect specular highlights (shiny surfaces)
            let t4 = CACurrentMediaTime()
            metrics.specularScore = detectSpecularHighlights(in: downsampledImage)
            trackTime("specularHighlights", startTime: t4)
            
            // Calculate diffuse reflection score
            let t5 = CACurrentMediaTime()
            metrics.diffuseScore = calculateDiffuseReflection(in: downsampledImage)
            trackTime("diffuseReflection", startTime: t5)
            
            // Determine surface type based on metrics
            let t6 = CACurrentMediaTime()
            metrics.surfaceType = classifySurface(metrics)
            trackTime("classifySurface", startTime: t6)
            
            // Log total time and component times
            let totalTime = CACurrentMediaTime() - startTime
            
            return metrics
        }
    }
    
    /// Downsample an image to reduce processing load
    private func downsampleImage(_ image: CIImage, scale: CGFloat) -> CIImage {
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    
    /// Get the appropriate downsampling scale based on detection mode
    private func getDownsamplingScale() -> CGFloat {
        switch detectionMode {
        case .standard:
            return 0.25 // 25% of original size (balanced performance)
        case .highSensitivity:
            return 0.4 // 40% of original size (higher quality for faint inscriptions)
        case .archaeological:
            return 0.3 // 30% of original size (optimized for archaeological artifacts)
        }
    }
    
    // Enhanced helper method to track operation times with history
    private func trackTime(_ operation: String, startTime: TimeInterval) {
        let duration = CACurrentMediaTime() - startTime
        lastOperationTimes[operation] = duration
        
        // Add to history for trend analysis
        if operationTimeHistory[operation] == nil {
            operationTimeHistory[operation] = []
        }
        
        operationTimeHistory[operation]?.append(duration)
        
        // Trim history if needed
        if let history = operationTimeHistory[operation], history.count > maxTimeHistoryEntries {
            operationTimeHistory[operation]?.removeFirst()
        }
    }
    
    // Simplified logging with less output
    private func logOperationTimes() {
        // Only log if we're in verbose debug mode
        #if DEBUG
        if let slowestOp = lastOperationTimes.max(by: { $0.value < $1.value }) {
            print("DEBUG: Slowest operation: \(slowestOp.key) - \(slowestOp.value * 1000)ms")
        }
        #endif
    }
    
    // Calculate average time for an operation
    private func averageTimeForOperation(_ operation: String) -> TimeInterval {
        guard let history = operationTimeHistory[operation], !history.isEmpty else {
            return lastOperationTimes[operation] ?? 0
        }
        
        return history.reduce(0, +) / Double(history.count)
    }
    
    // MARK: - Private Methods
    
    /// Calculate the average brightness of the entire image
    private func calculateAverageBrightness(_ image: CIImage) -> Float {
        let extent = image.extent
        let avgFilter = CIFilter.areaAverage()
        avgFilter.setValue(image, forKey: kCIInputImageKey)
        avgFilter.setValue(extent, forKey: "inputExtent")
        
        guard let output = avgFilter.outputImage else { return 0.0 }
        var bitmap = [UInt8](repeating: 0, count: 4)
        // Use shared context instead of creating a new one
        ciContext.render(output,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)
        
        // Calculate luminance using standard RGB to luminance formula
        // Uses the standard Rec. 709 luminance formula (perceptual brightness weighting):
        // Red contributes ~21%,
        // Green contributes ~71% (human eyes most sensitive to green),
        // Blue contributes ~7%.
        let r = Float(bitmap[0]) / 255.0
        let g = Float(bitmap[1]) / 255.0
        let b = Float(bitmap[2]) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        
        return luminance
    }
    
    /// Update the brightness history for temporal analysis
    private func updateBrightnessHistory(_ brightness: Float) {
        brightnessHistory.append(brightness)
        if brightnessHistory.count > historyCapacity {
            brightnessHistory.removeFirst()
        }
    }
    
    /// Calculate variance in brightness across the image (spatial analysis)
    private func calculateBrightnessVariance(_ image: CIImage) -> Float {
        // Grid size depends on detection mode
        let gridSize = getGridSizeForVarianceCalculation()
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        let cellWidth = width / gridSize
        let cellHeight = height / gridSize
        
        var brightnessSamples: [Float] = []
        
        // Image is already downsampled in analyzeFrame
        
        // Sample brightness in each grid cell
        for x in 0..<gridSize {
            for y in 0..<gridSize {
                let rect = CGRect(x: x * cellWidth, y: y * cellHeight,
                                 width: cellWidth, height: cellHeight)
                
                let cellFilter = CIFilter.areaAverage()
                cellFilter.setValue(image, forKey: kCIInputImageKey)
                cellFilter.setValue(rect, forKey: "inputExtent")
                
                guard let output = cellFilter.outputImage else { continue }
                var bitmap = [UInt8](repeating: 0, count: 4)
                ciContext.render(output,
                              toBitmap: &bitmap,
                              rowBytes: 4,
                              bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                              format: .RGBA8,
                              colorSpace: nil)
                
                let brightness = Float(bitmap[0]) / 255.0
                brightnessSamples.append(brightness)
            }
        }
        
        // Calculate variance
        if brightnessSamples.isEmpty { return 0.0 }
        let mean = brightnessSamples.reduce(0, +) / Float(brightnessSamples.count)
        let variance = brightnessSamples.reduce(0) { $0 + pow($1 - mean, 2) } / Float(brightnessSamples.count)
        
        return variance
    }
    
    /// Get the appropriate grid size for variance calculation based on detection mode
    private func getGridSizeForVarianceCalculation() -> Int {
        switch detectionMode {
        case .standard:
            return 2 // 2×2 grid (balanced performance)
        case .highSensitivity:
            return 3 // 3×3 grid (more detailed analysis for faint inscriptions)
        case .archaeological:
            return 4 // 4×4 grid (more detailed analysis for archaeological artifacts)
        }
    }
    
    /// Detect specular highlights (very bright pixels) - improved from original
    private func detectSpecularHighlights(in image: CIImage) -> Float {
        // Apply adaptive thresholding based on overall image brightness and detection mode
        let avgBrightness = calculateAverageBrightness(image)
        
        // Adjust threshold based on detection mode
        let baseThreshold = getSpecularBaseThreshold()
        let adaptiveThreshold = max(baseThreshold, min(0.95, avgBrightness + getSpecularAdaptiveOffset()))
        
        // Create a threshold filter to isolate very bright areas
        let highlightFilter = CIFilter.colorThreshold()
        highlightFilter.setValue(image, forKey: kCIInputImageKey)
        highlightFilter.setValue(adaptiveThreshold, forKey: "inputThreshold")
        
        guard let highlights = highlightFilter.outputImage else { return 0.0 }
        
        // Calculate the percentage of pixels that are highlights
        let totalPixels = Float(Int(image.extent.width) * Int(image.extent.height))
        let highlightCount = countNonZeroPixels(in: highlights)
        
        return Float(highlightCount) / totalPixels
    }
    
    /// Get the base threshold for specular highlight detection based on detection mode
    private func getSpecularBaseThreshold() -> Float {
        switch detectionMode {
        case .standard:
            return 0.85 // Standard threshold
        case .highSensitivity:
            return 0.75 // Lower threshold to detect fainter highlights
        case .archaeological:
            return 0.80 // Intermediate threshold for archaeological artifacts
        }
    }
    
    /// Get the adaptive offset for specular highlight detection based on detection mode
    private func getSpecularAdaptiveOffset() -> Float {
        switch detectionMode {
        case .standard:
            return 0.2 // Standard offset
        case .highSensitivity:
            return 0.15 // Smaller offset for more sensitivity
        case .archaeological:
            return 0.25 // Larger offset for archaeological artifacts
        }
    }
    
    /// Count non-zero pixels in an image (helper for specular highlight detection)
    private func countNonZeroPixels(in image: CIImage) -> Int {
        autoreleasepool {
            // Downsampling scale depends on detection mode
            let extent = image.extent
            let divisor = getPixelCountingDivisor()
            let scale = max(1.0, min(extent.width, extent.height) / divisor)
            let downsampledImage = image.transformed(by: CGAffineTransform(scaleX: 1.0/scale, y: 1.0/scale))
            
            // Use shared context instead of creating a new one
            guard let cgImage = ciContext.createCGImage(downsampledImage, from: downsampledImage.extent) else { return 0 }
            
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerRow = width * 4
            let totalBytes = bytesPerRow * height
            
            // Use a fixed buffer size to avoid allocating large buffers
            let maxBufferSize = 4096 // 4KB buffer max
            let actualBufferSize = min(totalBytes, maxBufferSize)
            var buffer = [UInt8](repeating: 0, count: actualBufferSize)
            
            // Create bitmap context with smaller dimensions if needed
            let contextWidth = totalBytes > maxBufferSize ? min(width, 32) : width
            let contextHeight = totalBytes > maxBufferSize ? min(height, 32) : height
            let contextBytesPerRow = contextWidth * 4
            
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            
            guard let context = CGContext(
                data: &buffer,
                width: contextWidth,
                height: contextHeight,
                bitsPerComponent: 8,
                bytesPerRow: contextBytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return 0 }
            
            // Draw a scaled portion of the image
            let drawRect = CGRect(x: 0, y: 0, width: contextWidth, height: contextHeight)
            context.draw(cgImage, in: drawRect)
            
            // Sampling stride depends on detection mode
            let strideValue = getPixelSamplingStride()
            var count = 0
            for i in stride(from: 0, to: actualBufferSize, by: strideValue) {
                if i < actualBufferSize && (buffer[i] > 0 || buffer[i+1] > 0 || buffer[i+2] > 0) {
                    count += 1
                }
            }
            
            // Scale the count back up to approximate the original image
            let scaleFactor = (width * height) / (contextWidth * contextHeight)
            let multiplier = strideValue / 4 // Adjust for stride
            return count * multiplier * scaleFactor
        }
    }
    
    /// Calculate diffuse reflection score
    private func calculateDiffuseReflection(in image: CIImage) -> Float {
        autoreleasepool {
            // For diffuse reflection, we look for more evenly distributed brightness
            // rather than concentrated highlights
            
            // Skip the blur filter entirely for performance
            // Instead, use the original image and adjust the calculation
            
            // Calculate brightness variance directly
            let variance = calculateBrightnessVariance(image)
            
            // Lower variance indicates more diffuse reflection
            // Convert to a 0-1 score where 1 is perfectly diffuse
            // Adjusted calculation to compensate for skipping blur
            // Adjust diffuse calculation based on detection mode
            let varianceMultiplier = getDiffuseVarianceMultiplier()
            let diffuseScore = 1.0 - min(1.0, variance * varianceMultiplier)
            
            return diffuseScore
        }
    }
    
    /// Get the appropriate divisor for pixel counting downsampling based on detection mode
    private func getPixelCountingDivisor() -> CGFloat {
        switch detectionMode {
        case .standard:
            return 20.0 // Standard divisor
        case .highSensitivity:
            return 15.0 // Less aggressive downsampling for higher sensitivity
        case .archaeological:
            return 18.0 // Intermediate downsampling for archaeological artifacts
        }
    }
    
    /// Get the appropriate stride for pixel sampling based on detection mode
    private func getPixelSamplingStride() -> Int {
        switch detectionMode {
        case .standard:
            return 64 // Sample every 16th pixel (standard)
        case .highSensitivity:
            return 32 // Sample every 8th pixel (more detailed)
        case .archaeological:
            return 48 // Sample every 12th pixel (intermediate)
        }
    }
    
    /// Get the appropriate variance multiplier for diffuse calculation based on detection mode
    private func getDiffuseVarianceMultiplier() -> Float {
        switch detectionMode {
        case .standard:
            return 8.0 // Standard multiplier
        case .highSensitivity:
            return 6.0 // Lower multiplier for higher sensitivity to subtle variations
        case .archaeological:
            return 10.0 // Higher multiplier optimized for archaeological artifacts
        }
    }
    
    /// Classify surface type based on reflectivity metrics
    private func classifySurface(_ metrics: ReflectivityMetrics) -> SurfaceType {
        // Use temporal analysis to improve stability
        let stableSpecularScore = calculateStableMetric(metrics.specularScore)
        
        // Apply calibration-adjusted thresholds with detection mode adjustments
        let adjustedVarianceThreshold = getVarianceThreshold()
        let adjustedDiffuseThreshold = diffuseThreshold
        let specularScoreThreshold = getSpecularScoreThreshold()
        
        // Classification logic with calibration-adjusted thresholds
        if stableSpecularScore > specularScoreThreshold &&
           metrics.brightnessVariance > adjustedVarianceThreshold {
            return .shiny
        } else if metrics.diffuseScore > adjustedDiffuseThreshold {
            return .matte
        } else {
            return .unknown
        }
    }
    
    /// Get the appropriate variance threshold for surface classification based on detection mode
    private func getVarianceThreshold() -> Float {
        let baseThreshold = max(0.01, brightnessVarianceBaseline)
        
        switch detectionMode {
        case .standard:
            return baseThreshold * 1.5 // Standard multiplier
        case .highSensitivity:
            return baseThreshold * 1.2 // Lower threshold for higher sensitivity
        case .archaeological:
            return baseThreshold * 1.8 // Higher threshold for archaeological artifacts
        }
    }
    
    /// Get the appropriate specular score threshold for surface classification based on detection mode
    private func getSpecularScoreThreshold() -> Float {
        switch detectionMode {
        case .standard:
            return 0.05 * specularThresholdAdjustment // Standard threshold
        case .highSensitivity:
            return 0.03 * specularThresholdAdjustment // Lower threshold for higher sensitivity
        case .archaeological:
            return 0.07 * specularThresholdAdjustment // Higher threshold for archaeological artifacts
        }
    }
    
    /// Calculate a stable metric using temporal analysis
    private func calculateStableMetric(_ currentValue: Float) -> Float {
        if brightnessHistory.isEmpty {
            return currentValue
        }
        
        // Use exponential moving average for stability
        // Alpha value depends on detection mode
        let alpha = getAlphaForTemporalSmoothing()
        let historicalAverage = brightnessHistory.reduce(0, +) / Float(brightnessHistory.count)
        return alpha * currentValue + (1 - alpha) * historicalAverage
    }
    
    /// Get the appropriate alpha value for temporal smoothing based on detection mode
    private func getAlphaForTemporalSmoothing() -> Float {
        switch detectionMode {
        case .standard:
            return 0.3 // Standard smoothing
        case .highSensitivity:
            return 0.2 // More smoothing for stability with faint inscriptions
        case .archaeological:
            return 0.4 // Less smoothing for archaeological artifacts
        }
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