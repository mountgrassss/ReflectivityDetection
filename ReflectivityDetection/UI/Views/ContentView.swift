import SwiftUI
import ARKit
import Combine

struct ContentView: View {
    @StateObject private var viewModel = ReflectivityViewModel()
    @State private var showSettings = false
    
    
    var body: some View {
        ZStack {
            // AR View takes the full screen
            ARViewContainer(metricsPublisher: viewModel.metricsPublisher,
                           bufferMetricsPublisher: viewModel.bufferMetricsPublisher,
                           showHighlights: viewModel.highlightReflectiveAreas,
                           highlightIntensity: viewModel.sensitivityThreshold,
                           detectionMode: viewModel.detectionMode)
                .edgesIgnoringSafeArea(.all)
            
            // Overlay UI elements
            VStack {
                // Top status bar
                HStack {
                    Text("Reflectivity Detection")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "gear")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                    }
                }
                .padding()
                .background(Color.black.opacity(0.5))
                
                Spacer()
                
                // Bottom panel with detection results
                VStack(spacing: 10) {
                    // Surface type indicator
                    HStack {
                        Circle()
                            .fill(viewModel.surfaceTypeColor)
                            .frame(width: 20, height: 20)
                        
                        Text(viewModel.surfaceType)
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        // Debug indicator
                        if viewModel.bufferMetrics.dropRate > 0.1 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                Text("\(Int(viewModel.bufferMetrics.dropRate * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.yellow)
                            }
                        }
                    }
                    
                    // Metrics display
                    VStack(alignment: .leading, spacing: 5) {
                        MetricRow(label: "Specular", value: viewModel.specularScore)
                        MetricRow(label: "Diffuse", value: viewModel.diffuseScore)
                        MetricRow(label: "Brightness", value: viewModel.averageBrightness)
                        
                        // Variance with threshold indicator
                        HStack {
                            MetricRow(label: "Variance", value: viewModel.brightnessVariance)
                            
                            // Show indicator when variance exceeds threshold
                            if viewModel.brightnessVariance > viewModel.varianceThreshold {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                    .font(.caption)
                            }
                        }
                        
                        MetricRow(label: "Var Threshold", value: viewModel.varianceThreshold)
                    }
                    
                    // Description of detected surface
                    Text(viewModel.surfaceDescription)
                        .font(.caption)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(15)
                .padding()
                
                // Debug metrics panel (collapsible)
                if viewModel.showDebugInfo {
                    VStack(spacing: 5) {
                        HStack {
                            Text("AR Buffer Metrics")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Button(action: {
                                viewModel.showDebugInfo.toggle()
                            }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.white)
                                    .font(.caption)
                            }
                        }
                        
                        Divider()
                            .background(Color.white.opacity(0.3))
                        
                        // Buffer metrics
                        Group {
                            HStack {
                                Text("Buffer Queue:")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                Text("\(viewModel.bufferMetrics.bufferQueueLength)/3")
                                    .font(.caption)
                                    .foregroundColor(viewModel.bufferMetrics.bufferQueueLength > 2 ? .red : .green)
                            }
                            
                            HStack {
                                Text("Drop Rate:")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(String(format: "%.1f%%", viewModel.bufferMetrics.dropRate * 100))
                                    .font(.caption)
                                    .foregroundColor(viewModel.bufferMetrics.dropRate > 0.1 ? .red : .green)
                            }
                            
                            HStack {
                                Text("Processing Time:")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(String(format: "%.1f ms", viewModel.bufferMetrics.averageProcessingTime * 1000))
                                    .font(.caption)
                                    .foregroundColor(viewModel.bufferMetrics.averageProcessingTime > 0.033 ? .red : .green)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.top, 5)
                } else {
                    // Small debug toggle button
                    Button(action: {
                        viewModel.showDebugInfo.toggle()
                    }) {
                        HStack {
                            Image(systemName: "ladybug")
                            Text("Debug")
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                    }
                    .padding(.top, 5)
                }
            }
            
            // Settings sheet
            if showSettings {
                SettingsView(isShowing: $showSettings, viewModel: viewModel)
                    .transition(.move(edge: .bottom))
                    .animation(.easeInOut, value: showSettings)
            }
            
            // Calibration overlay view
            if viewModel.isCalibrating {
                CalibrationOverlayView(viewModel: viewModel)
                    .transition(.opacity)
                    .animation(.easeInOut, value: viewModel.isCalibrating)
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            print("ContentView appeared")
        }
    }
}

// MARK: - AR View Container

struct ARViewContainer: UIViewRepresentable {
    var metricsPublisher: PassthroughSubject<ReflectivityMetrics, Never>
    var bufferMetricsPublisher: PassthroughSubject<ARBufferMetrics, Never>? = nil
    var showHighlights: Bool
    var highlightIntensity: Double
    var detectionMode: Int
    
    // Add Coordinator class to maintain a strong reference to the controller
    class Coordinator {
        var controller: ReflectivityViewController
        
        init(metricsPublisher: PassthroughSubject<ReflectivityMetrics, Never>,
             bufferMetricsPublisher: PassthroughSubject<ARBufferMetrics, Never>?,
             showHighlights: Bool,
             highlightIntensity: Double,
             detectionMode: Int) {
            self.controller = ReflectivityViewController()
            self.controller.metricsPublisher = metricsPublisher
            if let bufferPublisher = bufferMetricsPublisher {
                self.controller.bufferMetricsPublisher = bufferPublisher
            }
            self.controller.updateHighlightSettings(show: showHighlights, intensity: highlightIntensity)
            self.controller.updateDetectionMode(detectionMode)
        }
    }
    
    // Create and return the coordinator
    func makeCoordinator() -> Coordinator {
        Coordinator(metricsPublisher: metricsPublisher,
                   bufferMetricsPublisher: bufferMetricsPublisher,
                   showHighlights: showHighlights,
                   highlightIntensity: highlightIntensity,
                   detectionMode: detectionMode)
    }
    
    func makeUIView(context: Context) -> UIView {
        // Use the controller from the coordinator
        let controller = context.coordinator.controller
        
        // Return the view controller's view
        return controller.view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Updates when SwiftUI state changes
        // Update highlight settings when they change
        context.coordinator.controller.updateHighlightSettings(
            show: showHighlights,
            intensity: highlightIntensity
        )
        
        // Update detection mode when it changes
        context.coordinator.controller.updateDetectionMode(detectionMode)
    }
}

// MARK: - Supporting Views

struct MetricRow: View {
    var label: String
    var value: Float
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
                .frame(width: 80, alignment: .leading)
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    Rectangle()
                        .frame(width: geometry.size.width, height: 6)
                        .opacity(0.3)
                        .foregroundColor(.gray)
                    
                    // Value
                    Rectangle()
                        .frame(width: min(CGFloat(value) * geometry.size.width, geometry.size.width), height: 6)
                        .foregroundColor(barColor(for: value))
                }
            }
            .frame(height: 6)
            
            // Numeric value
            Text(String(format: "%.2f", value))
                .foregroundColor(.white)
                .frame(width: 50, alignment: .trailing)
                .font(.caption)
        }
    }
    
    private func barColor(for value: Float) -> Color {
        switch value {
        case 0..<0.3:
            return .blue
        case 0.3..<0.7:
            return .green
        default:
            return .yellow
        }
    }
}

struct SettingsView: View {
    @Binding var isShowing: Bool
    @ObservedObject var viewModel: ReflectivityViewModel
    
    var body: some View {
        VStack {
            HStack {
                Text("Settings")
                    .font(.title)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: {
                    isShowing = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.gray)
                }
            }
            .padding()
            
            Form {
                Section(header: Text("Detection Settings")) {
                    Toggle("Enhanced Detection", isOn: $viewModel.enhancedDetection)
                        .onChange(of: viewModel.enhancedDetection) { _ in viewModel.saveSettings() }
                    
                    Toggle("Show Highlights", isOn: $viewModel.showHighlights)
                        .onChange(of: viewModel.showHighlights) { _ in viewModel.saveSettings() }
                    
                    Picker("Detection Mode", selection: $viewModel.detectionMode) {
                        Text("Standard").tag(0)
                        Text("High Sensitivity").tag(1)
                        Text("Archaeological").tag(2)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: viewModel.detectionMode) { _ in
                        viewModel.saveSettings()
                        // No need for additional code here as the view will be updated automatically
                        // and the detection mode will be passed to the controller through the ARViewContainer
                    }
                }
                
                Section(header: Text("Visualization")) {
                    Toggle("Show Metrics", isOn: $viewModel.showMetrics)
                        .onChange(of: viewModel.showMetrics) { _ in viewModel.saveSettings() }
                    
                    Toggle("Highlight Reflective Areas", isOn: $viewModel.highlightReflectiveAreas)
                        .onChange(of: viewModel.highlightReflectiveAreas) { _ in viewModel.saveSettings() }
                    
                    Slider(value: $viewModel.sensitivityThreshold, in: 0...1) {
                        Text("Highlight Intensity")
                    }
                    .onChange(of: viewModel.sensitivityThreshold) { _ in viewModel.saveSettings() }
                }
                
                Section(header: Text("About")) {
                    Text("Reflectivity Detection App v1.0")
                        .font(.caption)
                    Text("Designed for archaeological inscription analysis")
                        .font(.caption)
                }
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(15)
        .padding()
    }
}

// MARK: - Calibration Overlay View (Missing Implementation)
struct CalibrationOverlayView: View {
    @ObservedObject var viewModel: ReflectivityViewModel
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 30) {
                Text("Calibration Required")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 15) {
                    InstructionRow(number: 1, text: "Point your device at a well-lit, neutral surface")
                    InstructionRow(number: 2, text: "Hold steady for a few seconds")
                    InstructionRow(number: 3, text: "Move slowly in a figure-8 pattern")
                }
                .padding()
                .background(Color.black.opacity(0.5))
                .cornerRadius(10)
                
                Button(action: {
                    viewModel.completeCalibration()
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}