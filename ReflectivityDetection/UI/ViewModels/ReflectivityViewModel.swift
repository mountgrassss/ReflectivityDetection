import SwiftUI
import Combine

class ReflectivityViewModel: ObservableObject {
    // Published properties for UI updates
    @Published var surfaceType: String = "Unknown"
    @Published var surfaceDescription: String = "Analyzing surface..."
    @Published var surfaceTypeColor: Color = .gray
    @Published var specularScore: Float = 0.0
    @Published var diffuseScore: Float = 0.0
    @Published var brightnessVariance: Float = 0.0
    @Published var averageBrightness: Float = 0.0
    
    // Debug metrics for AR buffer monitoring
    @Published var bufferMetrics = ARBufferMetrics()
    @Published var showDebugInfo: Bool = true
    
    // Calibration state properties
    @Published var isCalibrating: Bool = false
    @Published var calibrationCompleted: Bool = false
    
    // Settings properties
    @Published var enhancedDetection: Bool = true
    @Published var showHighlights: Bool = true
    @Published var detectionMode: Int = 0
    @Published var showMetrics: Bool = true
    @Published var highlightReflectiveAreas: Bool = true
    @Published var sensitivityThreshold: Double = 0.7
    
    // Calibration data collection
    private var calibrationMetrics: [ReflectivityMetrics] = []
    private let requiredCalibrationSamples = 10
    
    // Publishers to receive updates from AR controller
    let metricsPublisher = PassthroughSubject<ReflectivityMetrics, Never>()
    let bufferMetricsPublisher = PassthroughSubject<ARBufferMetrics, Never>()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Check if first launch/calibration needed
        let defaults = UserDefaults.standard
        calibrationCompleted = defaults.bool(forKey: "ReflectivityDetection.hasBeenCalibrated")
        isCalibrating = !calibrationCompleted
        
        // Load settings from UserDefaults
        loadSettings()
        
        // Subscribe to metrics updates
        metricsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] metrics in
                self?.updateFromMetrics(metrics)
                
                // Collect metrics during calibration
                if let self = self, self.isCalibrating {
                    self.collectCalibrationMetrics(metrics)
                }
            }
            .store(in: &cancellables)
            
        // Subscribe to buffer metrics updates
        bufferMetricsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] metrics in
                self?.bufferMetrics = metrics
            }
            .store(in: &cancellables)
        
        print("ReflectivityViewModel initialized")
        print("isCalibrating = \(isCalibrating)")
        print("calibrationCompleted = \(calibrationCompleted)")
    }
    
    // MARK: - Settings Management
    
    /// Loads user settings from UserDefaults
    private func loadSettings() {
        let defaults = UserDefaults.standard
        
        enhancedDetection = defaults.bool(forKey: "ReflectivityDetection.enhancedDetection", defaultValue: true)
        showHighlights = defaults.bool(forKey: "ReflectivityDetection.showHighlights", defaultValue: true)
        detectionMode = defaults.integer(forKey: "ReflectivityDetection.detectionMode", defaultValue: 0)
        showMetrics = defaults.bool(forKey: "ReflectivityDetection.showMetrics", defaultValue: true)
        highlightReflectiveAreas = defaults.bool(forKey: "ReflectivityDetection.highlightReflectiveAreas", defaultValue: true)
        sensitivityThreshold = defaults.double(forKey: "ReflectivityDetection.sensitivityThreshold", defaultValue: 0.7)
    }
    
    /// Saves user settings to UserDefaults
    func saveSettings() {
        let defaults = UserDefaults.standard
        
        defaults.set(enhancedDetection, forKey: "ReflectivityDetection.enhancedDetection")
        defaults.set(showHighlights, forKey: "ReflectivityDetection.showHighlights")
        defaults.set(detectionMode, forKey: "ReflectivityDetection.detectionMode")
        defaults.set(showMetrics, forKey: "ReflectivityDetection.showMetrics")
        defaults.set(highlightReflectiveAreas, forKey: "ReflectivityDetection.highlightReflectiveAreas")
        defaults.set(sensitivityThreshold, forKey: "ReflectivityDetection.sensitivityThreshold")
        
        // Log settings changes for debugging
        print("Settings updated - Highlights: \(highlightReflectiveAreas), Sensitivity: \(sensitivityThreshold)")
    }
    
    private func updateFromMetrics(_ metrics: ReflectivityMetrics) {
        // Update all the published properties
        surfaceType = metrics.surfaceType.rawValue
        surfaceDescription = metrics.surfaceType.description
        surfaceTypeColor = metrics.surfaceType.color
        specularScore = metrics.specularScore
        diffuseScore = metrics.diffuseScore
        brightnessVariance = metrics.brightnessVariance
        averageBrightness = metrics.averageBrightness
    }
    
    /// Collects metrics during calibration phase
    private func collectCalibrationMetrics(_ metrics: ReflectivityMetrics) {
        calibrationMetrics.append(metrics)
        print("Collected calibration sample \(calibrationMetrics.count)/\(requiredCalibrationSamples)")
        
        // Auto-complete calibration when we have enough samples
        if calibrationMetrics.count >= requiredCalibrationSamples {
            completeCalibration()
        }
    }
    
    /// Completes the calibration process by:
    /// 1. Calculating baseline values from collected metrics
    /// 2. Storing calibration parameters in UserDefaults
    /// 3. Updating state variables
    func completeCalibration() {
        guard !calibrationMetrics.isEmpty else {
            print("Warning: Completing calibration without any metrics")
            // Still update state even if we don't have metrics
            isCalibrating = false
            calibrationCompleted = true
            UserDefaults.standard.set(true, forKey: "ReflectivityDetection.hasBeenCalibrated")
            return
        }
        
        // Calculate average values from collected calibration metrics
        let avgSpecularScore = calibrationMetrics.map { $0.specularScore }.reduce(0, +) / Float(calibrationMetrics.count)
        let avgDiffuseScore = calibrationMetrics.map { $0.diffuseScore }.reduce(0, +) / Float(calibrationMetrics.count)
        let avgBrightnessVariance = calibrationMetrics.map { $0.brightnessVariance }.reduce(0, +) / Float(calibrationMetrics.count)
        let avgBrightness = calibrationMetrics.map { $0.averageBrightness }.reduce(0, +) / Float(calibrationMetrics.count)
        
        // Calculate calibration parameters based on collected data
        // These will be used to adjust thresholds for better detection
        let specularThresholdAdjustment = calculateSpecularThresholdAdjustment(avgSpecularScore)
        let diffuseThresholdAdjustment = calculateDiffuseThresholdAdjustment(avgDiffuseScore)
        let brightnessVarianceBaseline = max(0.01, avgBrightnessVariance)
        
        // Store calibration values in UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(avgSpecularScore, forKey: "ReflectivityDetection.baselineSpecularScore")
        defaults.set(avgDiffuseScore, forKey: "ReflectivityDetection.baselineDiffuseScore")
        defaults.set(avgBrightnessVariance, forKey: "ReflectivityDetection.baselineBrightnessVariance")
        defaults.set(avgBrightness, forKey: "ReflectivityDetection.baselineAverageBrightness")
        defaults.set(specularThresholdAdjustment, forKey: "ReflectivityDetection.specularThresholdAdjustment")
        defaults.set(diffuseThresholdAdjustment, forKey: "ReflectivityDetection.diffuseThresholdAdjustment")
        defaults.set(brightnessVarianceBaseline, forKey: "ReflectivityDetection.brightnessVarianceBaseline")
        
        // Mark calibration as completed
        defaults.set(true, forKey: "ReflectivityDetection.hasBeenCalibrated")
        
        // Update state variables
        isCalibrating = false
        calibrationCompleted = true
        
        // Clear calibration metrics to free memory
        calibrationMetrics.removeAll()
        
        print("Calibration completed successfully")
        print("Baseline values - Specular: \(avgSpecularScore), Diffuse: \(avgDiffuseScore), Variance: \(avgBrightnessVariance)")
    }
    
    /// Calculates an adjustment factor for specular threshold based on calibration data
    private func calculateSpecularThresholdAdjustment(_ baselineScore: Float) -> Float {
        // If baseline is very low (non-reflective environment), lower the threshold
        // If baseline is high (already reflective environment), raise the threshold
        if baselineScore < 0.02 {
            return 0.8 // Lower threshold to be more sensitive
        } else if baselineScore > 0.1 {
            return 1.2 // Raise threshold to be less sensitive
        } else {
            return 1.0 // Keep default threshold
        }
    }
    
    /// Calculates an adjustment factor for diffuse threshold based on calibration data
    private func calculateDiffuseThresholdAdjustment(_ baselineScore: Float) -> Float {
        // Similar logic to specular, but inverted since diffuse is opposite of specular
        if baselineScore > 0.8 {
            return 0.9 // Lower threshold to be more sensitive to diffuse surfaces
        } else if baselineScore < 0.5 {
            return 1.1 // Raise threshold to be less sensitive
        } else {
            return 1.0 // Keep default threshold
        }
    }
}

// MARK: - UserDefaults Extension
extension UserDefaults {
    func bool(forKey key: String, defaultValue: Bool) -> Bool {
        return object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
    
    func integer(forKey key: String, defaultValue: Int) -> Int {
        return object(forKey: key) == nil ? defaultValue : integer(forKey: key)
    }
    
    func double(forKey key: String, defaultValue: Double) -> Double {
        return object(forKey: key) == nil ? defaultValue : double(forKey: key)
    }
}