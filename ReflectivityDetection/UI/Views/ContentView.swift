import SwiftUI
import ARKit
import Combine

struct ContentView: View {
    @StateObject private var viewModel = ReflectivityViewModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // AR View takes the full screen
            ARViewContainer(
                metricsPublisher: viewModel.metricsPublisher,
                bufferMetricsPublisher: viewModel.bufferMetricsPublisher,
                showHighlights: viewModel.highlightReflectiveAreas,
                highlightIntensity: viewModel.sensitivityThreshold,
                detectionMode: viewModel.detectionMode
            )
            .edgesIgnoringSafeArea(.all)

            // Overlay UI elements
            VStack(spacing: 0) {
                // Top status bar
                HStack {
                    // Surface type badge
                    HStack(spacing: 8) {
                        Circle()
                            .fill(viewModel.surfaceTypeColor)
                            .frame(width: 12, height: 12)

                        Text(viewModel.surfaceType)
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.5))
                    )
                    .animation(
                        .easeInOut(duration: 0.3),
                        value: viewModel.surfaceType
                    )

                    Spacer()

                    // Drop rate warning
                    if viewModel.bufferMetrics.dropRate > 0.1 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("\(Int(viewModel.bufferMetrics.dropRate * 100))%")
                                .font(.caption2)
                        }
                        .foregroundColor(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.5))
                        )
                    }

                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                            )
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()

                // Bottom metrics panel
                if viewModel.showMetrics {
                    metricsPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Debug metrics panel (collapsed by default)
                if viewModel.showDebugInfo {
                    debugPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    debugToggleButton
                }
            }

            // Calibration overlay view
            if viewModel.isCalibrating {
                CalibrationOverlayView(viewModel: viewModel)
                    .transition(.opacity)
                    .animation(
                        .easeInOut,
                        value: viewModel.isCalibrating
                    )
            }

            // Recalibration prompt overlay
            if viewModel.showRecalibrationPrompt {
                RecalibrationPromptView(viewModel: viewModel)
                    .transition(.opacity)
                    .animation(
                        .easeInOut,
                        value: viewModel.showRecalibrationPrompt
                    )
            }

            // Calibration completed feedback toast
            if viewModel.showCalibrationCompletedFeedback {
                CalibrationCompletedView()
                    .transition(
                        .move(edge: .bottom).combined(with: .opacity)
                    )
                    .animation(
                        .easeInOut,
                        value: viewModel.showCalibrationCompletedFeedback
                    )
            }
        }
        .statusBar(hidden: true)
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
    }

    // MARK: - Metrics Panel

    private var metricsPanel: some View {
        VStack(spacing: 8) {
            // Surface description
            Text(viewModel.surfaceDescription)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)

            // Metrics
            MetricRow(
                label: "Specular",
                value: viewModel.specularScore,
                color: .cyan
            )
            MetricRow(
                label: "Diffuse",
                value: viewModel.diffuseScore,
                color: .green
            )
            MetricRow(
                label: "Brightness",
                value: viewModel.averageBrightness,
                color: .yellow
            )

            HStack(spacing: 4) {
                MetricRow(
                    label: "Variance",
                    value: viewModel.brightnessVariance,
                    color: varianceBarColor
                )

                if viewModel.brightnessVariance > viewModel.varianceThreshold {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.orange)
                        .font(.caption2)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var varianceBarColor: Color {
        viewModel.brightnessVariance > viewModel.varianceThreshold
            ? .orange : .blue
    }

    // MARK: - Debug Panel

    private var debugPanel: some View {
        VStack(spacing: 4) {
            HStack {
                Text("AR Buffer")
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    withAnimation { viewModel.showDebugInfo = false }
                }) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.caption2)
                }
            }

            Divider()
                .background(Color.white.opacity(0.2))

            debugRow(
                "Queue",
                value: "\(viewModel.bufferMetrics.bufferQueueLength)/3",
                warning: viewModel.bufferMetrics.bufferQueueLength > 2
            )
            debugRow(
                "Drop Rate",
                value: String(
                    format: "%.1f%%",
                    viewModel.bufferMetrics.dropRate * 100
                ),
                warning: viewModel.bufferMetrics.dropRate > 0.1
            )
            debugRow(
                "Proc. Time",
                value: String(
                    format: "%.1f ms",
                    viewModel.bufferMetrics.averageProcessingTime * 1000
                ),
                warning: viewModel.bufferMetrics.averageProcessingTime > 0.033
            )
            debugRow(
                "Var Thresh",
                value: String(
                    format: "%.4f",
                    viewModel.varianceThreshold
                ),
                warning: false
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.75))
        )
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func debugRow(
        _ label: String,
        value: String,
        warning: Bool
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(warning ? .red : .green)
        }
    }

    private var debugToggleButton: some View {
        Button(action: {
            withAnimation { viewModel.showDebugInfo = true }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "ladybug")
                Text("Debug")
            }
            .font(.caption2)
            .foregroundColor(.white.opacity(0.6))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.4))
            )
        }
        .padding(.bottom, 4)
    }
}

// MARK: - AR View Container

struct ARViewContainer: UIViewRepresentable {
    var metricsPublisher: PassthroughSubject<ReflectivityMetrics, Never>
    var bufferMetricsPublisher: PassthroughSubject<ARBufferMetrics, Never>?
    var showHighlights: Bool
    var highlightIntensity: Double
    var detectionMode: Int

    class Coordinator {
        var controller: ReflectivityViewController

        init(
            metricsPublisher: PassthroughSubject<ReflectivityMetrics, Never>,
            bufferMetricsPublisher: PassthroughSubject<ARBufferMetrics, Never>?,
            showHighlights: Bool,
            highlightIntensity: Double,
            detectionMode: Int
        ) {
            self.controller = ReflectivityViewController()
            self.controller.metricsPublisher = metricsPublisher
            if let bufferPublisher = bufferMetricsPublisher {
                self.controller.bufferMetricsPublisher = bufferPublisher
            }
            self.controller.updateHighlightSettings(
                show: showHighlights,
                intensity: highlightIntensity
            )
            self.controller.updateDetectionMode(detectionMode)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            metricsPublisher: metricsPublisher,
            bufferMetricsPublisher: bufferMetricsPublisher,
            showHighlights: showHighlights,
            highlightIntensity: highlightIntensity,
            detectionMode: detectionMode
        )
    }

    func makeUIView(context: Context) -> UIView {
        return context.coordinator.controller.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.controller.updateHighlightSettings(
            show: showHighlights,
            intensity: highlightIntensity
        )
        context.coordinator.controller.updateDetectionMode(detectionMode)
    }
}

// MARK: - Metric Row

struct MetricRow: View {
    var label: String
    var value: Float
    var color: Color = .blue

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 72, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 6)

                    // Value bar with smooth animation
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [
                                    color.opacity(0.7),
                                    color
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(
                            width: min(
                                CGFloat(value) * geometry.size.width,
                                geometry.size.width
                            ),
                            height: 6
                        )
                        .animation(
                            .easeOut(duration: 0.25),
                            value: value
                        )
                }
            }
            .frame(height: 6)

            Text(String(format: "%.3f", value))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ReflectivityViewModel

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Detection Settings")) {
                    Toggle(
                        "Enhanced Detection",
                        isOn: $viewModel.enhancedDetection
                    )
                    .onChange(of: viewModel.enhancedDetection) { _ in
                        viewModel.saveSettings()
                    }

                    Toggle(
                        "Show Highlights",
                        isOn: $viewModel.showHighlights
                    )
                    .onChange(of: viewModel.showHighlights) { _ in
                        viewModel.saveSettings()
                    }

                    Picker(
                        "Detection Mode",
                        selection: $viewModel.detectionMode
                    ) {
                        Text("Standard").tag(0)
                        Text("High Sensitivity").tag(1)
                        Text("Archaeological").tag(2)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: viewModel.detectionMode) { _ in
                        viewModel.saveSettings()
                    }
                }

                Section(header: Text("Visualization")) {
                    Toggle(
                        "Show Metrics",
                        isOn: $viewModel.showMetrics
                    )
                    .onChange(of: viewModel.showMetrics) { _ in
                        viewModel.saveSettings()
                    }

                    Toggle(
                        "Highlight Reflective Areas",
                        isOn: $viewModel.highlightReflectiveAreas
                    )
                    .onChange(of: viewModel.highlightReflectiveAreas) { _ in
                        viewModel.saveSettings()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Highlight Intensity")
                            Spacer()
                            Text(
                                String(
                                    format: "%.0f%%",
                                    viewModel.sensitivityThreshold * 100
                                )
                            )
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        }
                        Slider(
                            value: $viewModel.sensitivityThreshold,
                            in: 0...1
                        )
                        .onChange(of: viewModel.sensitivityThreshold) { _ in
                            viewModel.saveSettings()
                        }
                    }
                }

                Section(header: Text("Calibration")) {
                    Button("Recalibrate System") {
                        viewModel.startRecalibration()
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }

                Section(header: Text("About")) {
                    Text("Reflectivity Detection App v1.0")
                        .font(.caption)
                    Text("Designed for archaeological inscription analysis")
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Calibration Overlay View

struct CalibrationOverlayView: View {
    @ObservedObject var viewModel: ReflectivityViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 25) {
                Text("Calibration Required")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 15) {
                    InstructionRow(
                        number: 1,
                        text: "Point your device at a well-lit, neutral surface"
                    )
                    InstructionRow(
                        number: 2,
                        text: "Hold steady for a few seconds"
                    )
                    InstructionRow(
                        number: 3,
                        text: "Move slowly in a figure-8 pattern"
                    )
                }
                .padding()
                .background(Color.black.opacity(0.5))
                .cornerRadius(10)

                // Calibration Progress Section
                VStack(spacing: 10) {
                    Text("Collecting calibration samples...")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(
                        "\(viewModel.calibrationSamplesCollected)/10 samples"
                    )
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))

                    // Progress Bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.2))
                                .frame(height: 8)

                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    LinearGradient(
                                        colors: [.blue, .cyan],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(
                                    width: min(
                                        CGFloat(viewModel.calibrationProgress)
                                            * geometry.size.width,
                                        geometry.size.width
                                    ),
                                    height: 8
                                )
                                .animation(
                                    .easeInOut(duration: 0.3),
                                    value: viewModel.calibrationProgress
                                )
                        }
                    }
                    .frame(height: 8)
                    .padding(.horizontal)
                }
                .padding()
                .background(Color.black.opacity(0.4))
                .cornerRadius(10)

                Button(action: {
                    withAnimation {
                        viewModel.completeCalibration()
                    }
                }) {
                    Text("Complete Calibration")
                        .font(.headline)
                        .foregroundColor(.black)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)
                .opacity(viewModel.calibrationProgress >= 1.0 ? 1.0 : 0.5)
                .disabled(viewModel.calibrationProgress < 1.0)
            }
            .padding()
        }
    }
}

struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 30, height: 30)

                Text("\(number)")
                    .font(.headline)
                    .foregroundColor(.black)
            }

            Text(text)
                .font(.body)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Recalibration Prompt View

struct RecalibrationPromptView: View {
    @ObservedObject var viewModel: ReflectivityViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)

                Text("Environment Change Detected")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text(
                    "The lighting or surface conditions have changed significantly. "
                    + "Recalibration is recommended for optimal detection."
                )
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

                HStack(spacing: 16) {
                    Button(action: {
                        withAnimation {
                            viewModel.showRecalibrationPrompt = false
                        }
                    }) {
                        Text("Continue")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.gray.opacity(0.6))
                            .cornerRadius(10)
                    }

                    Button(action: {
                        withAnimation {
                            viewModel.startRecalibration()
                        }
                    }) {
                        Text("Recalibrate")
                            .font(.headline)
                            .foregroundColor(.black)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.85))
            )
            .padding()
        }
    }
}

// MARK: - Calibration Completed Feedback View

struct CalibrationCompletedView: View {
    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)

                Text("Calibration Completed")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .shadow(
                        color: Color.black.opacity(0.3),
                        radius: 5,
                        x: 0,
                        y: 2
                    )
            )
            .padding(.horizontal)
            .padding(.bottom, 120)
        }
        .zIndex(100)
        .onAppear {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
