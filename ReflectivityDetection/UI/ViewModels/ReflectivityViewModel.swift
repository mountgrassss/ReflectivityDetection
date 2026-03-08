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
    @Published var varianceThreshold: Float = 0.0

    // Debug metrics for AR buffer monitoring
    @Published var bufferMetrics = ARBufferMetrics()
    @Published var showDebugInfo: Bool = false

    // Calibration state properties
    @Published var isCalibrating: Bool = false
    @Published var calibrationCompleted: Bool = false
    @Published var showRecalibrationPrompt: Bool = false
    @Published var showCalibrationCompletedFeedback: Bool = false
    @Published var calibrationProgress: Float = 0.0
    @Published var calibrationSamplesCollected: Int = 0

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

    // Environment change detection
    private var baselineSpecularScore: Float = 0.0
    private var baselineDiffuseScore: Float = 0.0
    private var baselineBrightnessVariance: Float = 0.0
    private var baselineAverageBrightness: Float = 0.0
    private var environmentCheckCounter: Int = 0
    private let environmentCheckFrequency: Int = 100
    private let environmentChangeThreshold: Float = 0.5

    // Publishers to receive updates from AR controller
    let metricsPublisher = PassthroughSubject<ReflectivityMetrics, Never>()
    let bufferMetricsPublisher = PassthroughSubject<ARBufferMetrics, Never>()
    private var cancellables = Set<AnyCancellable>()

    init() {
        let defaults = UserDefaults.standard
        calibrationCompleted = defaults.bool(
            forKey: "ReflectivityDetection.hasBeenCalibrated"
        )
        isCalibrating = !calibrationCompleted

        loadSettings()
        loadBaselineValues()

        metricsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] metrics in
                self?.updateFromMetrics(metrics)

                if let self = self, self.isCalibrating {
                    self.collectCalibrationMetrics(metrics)
                }
            }
            .store(in: &cancellables)

        bufferMetricsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] metrics in
                self?.bufferMetrics = metrics
            }
            .store(in: &cancellables)
    }

    // MARK: - Settings Management

    private func loadSettings() {
        let defaults = UserDefaults.standard

        enhancedDetection = defaults.bool(
            forKey: "ReflectivityDetection.enhancedDetection",
            defaultValue: true
        )
        showHighlights = defaults.bool(
            forKey: "ReflectivityDetection.showHighlights",
            defaultValue: true
        )
        detectionMode = defaults.integer(
            forKey: "ReflectivityDetection.detectionMode",
            defaultValue: 0
        )
        showMetrics = defaults.bool(
            forKey: "ReflectivityDetection.showMetrics",
            defaultValue: true
        )
        highlightReflectiveAreas = defaults.bool(
            forKey: "ReflectivityDetection.highlightReflectiveAreas",
            defaultValue: true
        )
        sensitivityThreshold = defaults.double(
            forKey: "ReflectivityDetection.sensitivityThreshold",
            defaultValue: 0.7
        )
    }

    func saveSettings() {
        let defaults = UserDefaults.standard

        defaults.set(
            enhancedDetection,
            forKey: "ReflectivityDetection.enhancedDetection"
        )
        defaults.set(
            showHighlights,
            forKey: "ReflectivityDetection.showHighlights"
        )
        defaults.set(
            detectionMode,
            forKey: "ReflectivityDetection.detectionMode"
        )
        defaults.set(
            showMetrics,
            forKey: "ReflectivityDetection.showMetrics"
        )
        defaults.set(
            highlightReflectiveAreas,
            forKey: "ReflectivityDetection.highlightReflectiveAreas"
        )
        defaults.set(
            sensitivityThreshold,
            forKey: "ReflectivityDetection.sensitivityThreshold"
        )
    }

    private func loadBaselineValues() {
        let defaults = UserDefaults.standard

        baselineSpecularScore = defaults.float(
            forKey: "ReflectivityDetection.baselineSpecularScore",
            defaultValue: 0.0
        )
        baselineDiffuseScore = defaults.float(
            forKey: "ReflectivityDetection.baselineDiffuseScore",
            defaultValue: 0.0
        )
        baselineBrightnessVariance = defaults.float(
            forKey: "ReflectivityDetection.baselineBrightnessVariance",
            defaultValue: 0.01
        )
        baselineAverageBrightness = defaults.float(
            forKey: "ReflectivityDetection.baselineAverageBrightness",
            defaultValue: 0.5
        )
    }

    // MARK: - Metrics Update

    private func updateFromMetrics(_ metrics: ReflectivityMetrics) {
        surfaceType = metrics.surfaceType.rawValue
        surfaceDescription = metrics.surfaceType.description
        surfaceTypeColor = metrics.surfaceType.color
        specularScore = metrics.specularScore
        diffuseScore = metrics.diffuseScore
        brightnessVariance = metrics.brightnessVariance
        averageBrightness = metrics.averageBrightness
        varianceThreshold = metrics.varianceThreshold

        // Check for environmental changes periodically
        if calibrationCompleted && !isCalibrating {
            environmentCheckCounter += 1
            if environmentCheckCounter >= environmentCheckFrequency {
                checkForEnvironmentalChanges(metrics)
                environmentCheckCounter = 0
            }
        }
    }

    // MARK: - Environment Change Detection

    private func checkForEnvironmentalChanges(
        _ metrics: ReflectivityMetrics
    ) {
        guard baselineSpecularScore > 0
            || baselineDiffuseScore > 0
            || baselineBrightnessVariance > 0 else {
            return
        }

        let specularChange = abs(metrics.specularScore - baselineSpecularScore)
            / max(0.01, baselineSpecularScore)
        let diffuseChange = abs(metrics.diffuseScore - baselineDiffuseScore)
            / max(0.01, baselineDiffuseScore)
        let varianceChange = abs(
            metrics.brightnessVariance - baselineBrightnessVariance
        ) / max(0.01, baselineBrightnessVariance)
        let brightnessChange = abs(
            metrics.averageBrightness - baselineAverageBrightness
        ) / max(0.01, baselineAverageBrightness)

        let overallChange = specularChange * 0.3
            + diffuseChange * 0.3
            + varianceChange * 0.2
            + brightnessChange * 0.2

        if overallChange > environmentChangeThreshold {
            showRecalibrationPrompt = true
        }
    }

    // MARK: - Calibration

    private func collectCalibrationMetrics(
        _ metrics: ReflectivityMetrics
    ) {
        calibrationMetrics.append(metrics)
        calibrationSamplesCollected = calibrationMetrics.count
        calibrationProgress = Float(calibrationMetrics.count)
            / Float(requiredCalibrationSamples)

        if calibrationMetrics.count >= requiredCalibrationSamples {
            completeCalibration()
        }
    }

    func completeCalibration() {
        guard !calibrationMetrics.isEmpty else {
            isCalibrating = false
            calibrationCompleted = true
            UserDefaults.standard.set(
                true,
                forKey: "ReflectivityDetection.hasBeenCalibrated"
            )
            return
        }

        let count = Float(calibrationMetrics.count)
        let avgSpecularScore = calibrationMetrics
            .map(\.specularScore).reduce(0, +) / count
        let avgDiffuseScore = calibrationMetrics
            .map(\.diffuseScore).reduce(0, +) / count
        let avgBrightnessVariance = calibrationMetrics
            .map(\.brightnessVariance).reduce(0, +) / count
        let avgBrightness = calibrationMetrics
            .map(\.averageBrightness).reduce(0, +) / count

        let specularThresholdAdjustment =
            calculateSpecularThresholdAdjustment(avgSpecularScore)
        let diffuseThresholdAdjustment =
            calculateDiffuseThresholdAdjustment(avgDiffuseScore)
        let brightnessVarianceBaseline = max(0.01, avgBrightnessVariance)

        let defaults = UserDefaults.standard
        defaults.set(
            avgSpecularScore,
            forKey: "ReflectivityDetection.baselineSpecularScore"
        )
        defaults.set(
            avgDiffuseScore,
            forKey: "ReflectivityDetection.baselineDiffuseScore"
        )
        defaults.set(
            avgBrightnessVariance,
            forKey: "ReflectivityDetection.baselineBrightnessVariance"
        )
        defaults.set(
            avgBrightness,
            forKey: "ReflectivityDetection.baselineAverageBrightness"
        )
        defaults.set(
            specularThresholdAdjustment,
            forKey: "ReflectivityDetection.specularThresholdAdjustment"
        )
        defaults.set(
            diffuseThresholdAdjustment,
            forKey: "ReflectivityDetection.diffuseThresholdAdjustment"
        )
        defaults.set(
            brightnessVarianceBaseline,
            forKey: "ReflectivityDetection.brightnessVarianceBaseline"
        )
        defaults.set(
            true,
            forKey: "ReflectivityDetection.hasBeenCalibrated"
        )

        isCalibrating = false
        calibrationCompleted = true
        showRecalibrationPrompt = false
        showCalibrationCompletedFeedback = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.showCalibrationCompletedFeedback = false
        }

        baselineSpecularScore = avgSpecularScore
        baselineDiffuseScore = avgDiffuseScore
        baselineBrightnessVariance = avgBrightnessVariance
        baselineAverageBrightness = avgBrightness

        calibrationMetrics.removeAll()
    }

    private func calculateSpecularThresholdAdjustment(
        _ baselineScore: Float
    ) -> Float {
        if baselineScore < 0.02 {
            return 0.8
        } else if baselineScore > 0.1 {
            return 1.2
        } else {
            return 1.0
        }
    }

    private func calculateDiffuseThresholdAdjustment(
        _ baselineScore: Float
    ) -> Float {
        if baselineScore > 0.8 {
            return 0.9
        } else if baselineScore < 0.5 {
            return 1.1
        } else {
            return 1.0
        }
    }

    func startRecalibration() {
        isCalibrating = true
        calibrationCompleted = false
        showRecalibrationPrompt = false
        calibrationMetrics.removeAll()
        calibrationProgress = 0.0
        calibrationSamplesCollected = 0
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

    func float(forKey key: String, defaultValue: Float = 0.0) -> Float {
        return object(forKey: key) == nil ? defaultValue : float(forKey: key)
    }
}
