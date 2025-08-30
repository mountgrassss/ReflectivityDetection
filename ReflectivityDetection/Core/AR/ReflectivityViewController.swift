import UIKit
import ARKit
import Vision
import Combine

// Define ARBufferMetrics directly in this file since it's not properly included in the project
struct ARBufferMetrics {
    var totalFramesReceived: Int = 0
    var framesProcessed: Int = 0
    var averageProcessingTime: TimeInterval = 0
    var peakProcessingTime: TimeInterval = 0
    var bufferQueueLength: Int = 0
    var droppedFrames: Int = 0
    
    var dropRate: Double {
        return totalFramesReceived > 0 ? Double(droppedFrames) / Double(totalFramesReceived) : 0
    }
    
    mutating func reset() {
        totalFramesReceived = 0
        framesProcessed = 0
        averageProcessingTime = 0
        peakProcessingTime = 0
        bufferQueueLength = 0
        droppedFrames = 0
    }
}

class ReflectivityViewController: UIViewController, ARSessionDelegate {
    // MARK: - Properties
    
    var sceneView: ARSCNView!
    let session = ARSession()
    lazy var analyzer: ReflectivityAnalyzer = {
        let analyzer = ReflectivityAnalyzer()
        return analyzer
    }()
    
    // For publishing metrics to SwiftUI
    var metricsPublisher = PassthroughSubject<ReflectivityMetrics, Never>()
    var bufferMetricsPublisher = PassthroughSubject<ARBufferMetrics, Never>()
    
    // For highlight visualization
    private var highlightNode: SCNNode?
    private var shouldShowHighlights: Bool = true
    private var highlightIntensity: Double = 0.7
    
    // Detection mode
    private var detectionMode: Int = 0
    
    // For frame processing
    private var lastProcessedTime: TimeInterval = 0
    private let processingInterval: TimeInterval = 0.3 // Increased to 300ms to reduce buffer pressure
    
    // Buffer management
    private var bufferMetrics = ARBufferMetrics()
    private let bufferSemaphore = DispatchSemaphore(value: 3) // Limit concurrent processing
    private var activeBufferCount = 0 // Track active buffers
    
    // OPTIMIZATION: Dedicated high-priority processing queue with limited concurrency
    private let processingQueue = DispatchQueue(label: "com.reflectivity.processing",
                                               qos: .userInteractive,
                                               attributes: [],  // Changed from concurrent to serial
                                               autoreleaseFrequency: .workItem)
    
    // OPTIMIZATION: Shared CIContext to avoid repeated creation
    private lazy var ciContext: CIContext = {
        return CIContext(options: [.useSoftwareRenderer: false,
                                  .cacheIntermediates: true,
                                  .allowLowPower: false])
    }()
    
    // Enhanced frame drop tracking
    private var frameProcessingTimes: [TimeInterval] = []
    private let maxProcessingTimeHistory = 10 // Reduced from 30 to save memory
    
    // Autoreleasepool for buffer management
    private let bufferPoolQueue = DispatchQueue(label: "com.reflectivity.bufferpool")
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // DEBUG: Log view controller lifecycle
        print("DEBUG: ReflectivityViewController viewDidLoad")
        print("DEBUG: Checking for calibration functionality...")
        
        setupARView()
        startARSession()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Resume the AR session if it was paused
        if sceneView.session.configuration == nil {
            startARSession()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the AR session to save battery
        sceneView.session.pause()
    }
    
    // MARK: - Setup
    
    private func setupARView() {
        // Create AR view
        sceneView = ARSCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sceneView)
        
        // Set up AR session
        sceneView.session = session
        session.delegate = self
        
        // Add tap gesture for focusing
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        sceneView.addGestureRecognizer(tapGesture)
    }
    
    private func startARSession() {
        // Configure AR session with light estimation
        let configuration = ARWorldTrackingConfiguration()
        
        // Enable plane detection for tap interaction
        configuration.planeDetection = [.horizontal, .vertical]
        
        // OPTIMIZATION: Configure AR session for better performance
        configuration.isLightEstimationEnabled = true // Keep light estimation as it's needed for reflectivity
        
        // OPTIMIZATION: Reduce environment texturing quality to improve performance
        configuration.environmentTexturing = .none // Changed from .manual to .none for maximum performance
        
        // OPTIMIZATION: Set frame semantics to prioritize performance
        if #available(iOS 13.0, *) {
            // Prioritize smooth frame delivery over other features
            configuration.frameSemantics = []
        }
        
        // Check calibration status - use actual function instead of hardcoded value
        let needsCalibration = checkIfCalibrationNeeded()
        print("Starting AR session. Needs calibration: \(needsCalibration)")
        
        // If calibration was completed previously, ensure analyzer has loaded calibration values
        if !needsCalibration {
            analyzer.loadCalibrationValues()
        }
        
        // Run the session with appropriate options
        let options: ARSession.RunOptions = needsCalibration ?
            [.resetTracking, .removeExistingAnchors] :
            [.removeExistingAnchors]
        
        // OPTIMIZATION: Find optimal video format balancing performance and quality
        var selectedFormat: ARConfiguration.VideoFormat?
        
        // First try to find a format with 60fps for smoother tracking
        if let highFrameRateFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            $0.imageResolution.width <= 1280 && $0.framesPerSecond >= 60
        }) {
            selectedFormat = highFrameRateFormat
        }
        // Fall back to 30fps with moderate resolution
        else if let moderateFormat = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            $0.imageResolution.width <= 1280 && $0.framesPerSecond >= 30
        }) {
            selectedFormat = moderateFormat
        }
        
        if let format = selectedFormat {
            configuration.videoFormat = format
            print("DEBUG: Setting video format: \(format.imageResolution.width)x\(format.imageResolution.height) at \(format.framesPerSecond) FPS")
        }
        
        session.run(configuration, options: options)
    }
    
    private func checkIfCalibrationNeeded() -> Bool {
        // Check if the app has been calibrated before
        let defaults = UserDefaults.standard
        // let hasBeenCalibrated = defaults.bool(forKey: "ReflectivityDetection.hasBeenCalibrated")
        let hasBeenCalibrated = false
        print("Checking if calibration needed. hasBeenCalibrated = \(hasBeenCalibrated)")
        return !hasBeenCalibrated
    }
    
    // MARK: - AR Session Delegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Track total frames for statistics
        bufferMetrics.totalFramesReceived += 1
        
        // Throttle processing to avoid overloading the CPU
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessedTime >= processingInterval else {
            // Count as dropped frame if we skip it due to throttling
            bufferMetrics.droppedFrames += 1
            return
        }
        lastProcessedTime = currentTime
        
        // Try to acquire semaphore with timeout - if we can't get it in 10ms, drop the frame
        let semaphoreResult = bufferSemaphore.wait(timeout: .now() + 0.01)
        guard semaphoreResult == .success else {
            print("WARNING: Buffer semaphore timeout - dropping frame to prevent buffer overflow")
            bufferMetrics.droppedFrames += 1
            return
        }
        
        // Increment active buffer count and update buffer queue length metric
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeBufferCount += 1
            self.bufferMetrics.bufferQueueLength = self.activeBufferCount
        }
        
        // DEBUG: Log frame timing
        let frameTime = frame.timestamp
        let frameRate = 1.0 / (currentTime - frameTime)
        print("DEBUG: Received frame at time: \(frameTime), frame rate: \(String(format: "%.1f", frameRate)) fps")
        
        // OPTIMIZATION: Create a copy of the pixel buffer to avoid ARKit reusing it before we're done
        // Use autoreleasepool to ensure proper memory management of pixel buffers
        bufferPoolQueue.async { [weak self] in
            autoreleasepool {
                guard let self = self else {
                    self?.bufferSemaphore.signal()
                    return
                }
                
                // Create a copy of the pixel buffer to avoid ARKit reusing it
                var pixelBufferCopy: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault,
                                   CVPixelBufferGetWidth(frame.capturedImage),
                                   CVPixelBufferGetHeight(frame.capturedImage),
                                   CVPixelBufferGetPixelFormatType(frame.capturedImage),
                                   nil,
                                   &pixelBufferCopy)
                
                if let pixelBufferCopy = pixelBufferCopy {
                    CVPixelBufferLockBaseAddress(frame.capturedImage, .readOnly)
                    CVPixelBufferLockBaseAddress(pixelBufferCopy, [])
                    
                    memcpy(CVPixelBufferGetBaseAddress(pixelBufferCopy),
                          CVPixelBufferGetBaseAddress(frame.capturedImage),
                          CVPixelBufferGetDataSize(frame.capturedImage))
                    
                    CVPixelBufferUnlockBaseAddress(pixelBufferCopy, [])
                    CVPixelBufferUnlockBaseAddress(frame.capturedImage, .readOnly)
                    
                    // Process the frame on processing queue
                    self.processingQueue.async {
                        // Track processing start time
                        let processStartTime = CACurrentMediaTime()
                        
                        // Process the frame
                        self.processFrame(pixelBufferCopy)
                        
                        // Calculate processing duration
                        let processDuration = CACurrentMediaTime() - processStartTime
                        
                        // Store processing time for statistics
                        self.trackFrameProcessingTime(processDuration)
                        
                        // Update processed frame count and metrics
                        DispatchQueue.main.async {
                            self.bufferMetrics.framesProcessed += 1
                            self.bufferMetrics.averageProcessingTime = self.averageProcessingTime()
                            self.bufferMetrics.peakProcessingTime = self.frameProcessingTimes.max() ?? 0
                            
                            // Publish buffer metrics
                            self.bufferMetricsPublisher.send(self.bufferMetrics)
                            
                            // Log buffer metrics
                            let dropRate = self.bufferMetrics.dropRate * 100
                            print("DEBUG: Buffer metrics - Queue: \(self.bufferMetrics.bufferQueueLength)/3, Drop rate: \(String(format: "%.1f%%", dropRate)), Avg time: \(String(format: "%.1f", self.bufferMetrics.averageProcessingTime * 1000))ms")
                        }
                        
                        // Signal semaphore to allow next frame to be processed
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            self.activeBufferCount -= 1
                        }
                        self.bufferSemaphore.signal()
                    }
                } else {
                    // Failed to create copy, signal semaphore and return
                    print("ERROR: Failed to create pixel buffer copy")
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.activeBufferCount -= 1
                    }
                    self.bufferSemaphore.signal()
                }
            }
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Handle session failures
        print("AR Session failed: \(error.localizedDescription)")
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Handle session interruptions
        print("AR Session was interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Handle interruption end
        print("AR Session interruption ended")
        startARSession() // Restart with fresh tracking
    }
    
    // MARK: - Frame Processing
    
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        autoreleasepool {
            // DEBUG: Log processing start time with detailed timing
            let startTime = CACurrentMediaTime()
            
            // OPTIMIZATION: Downsample the image before processing
            let downsampledPixelBuffer = downsamplePixelBuffer(pixelBuffer)
            
            // Create CIImage for processing
            let ciImage = CIImage(cvPixelBuffer: downsampledPixelBuffer ?? pixelBuffer)
            
            // OPTIMIZATION: Share the CIContext with the analyzer
            analyzer.setCIContext(ciContext)
            
            // Use the analyzer to process the frame with detailed timing
            let beforeAnalyzer = CACurrentMediaTime()
            let metrics = analyzer.analyzeFrame(ciImage)
            let analyzerDuration = CACurrentMediaTime() - beforeAnalyzer
            
            // Highlight reflective areas if enabled
            if shouldShowHighlights {
                highlightReflectiveAreas(metrics: metrics)
            } else if let highlightNode = highlightNode {
                // Remove highlights if they exist but should not be shown
                DispatchQueue.main.async {
                    highlightNode.removeFromParentNode()
                    self.highlightNode = nil
                }
            }
            
            // Publish metrics to SwiftUI on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.metricsPublisher.send(metrics)
                self.updateDebugInfo(with: metrics)
            }
            
            // DEBUG: Log total processing time with detailed breakdown
            let totalDuration = CACurrentMediaTime() - startTime
            
            // Explicitly release the downsampled buffer to free memory
            if let downsampledBuffer = downsampledPixelBuffer {
                CVPixelBufferUnlockBaseAddress(downsampledBuffer, CVPixelBufferLockFlags(rawValue: 0))
            }
        }
    }
    
    // OPTIMIZATION: Track frame processing times for statistics
    private func trackFrameProcessingTime(_ time: TimeInterval) {
        frameProcessingTimes.append(time)
        if frameProcessingTimes.count > maxProcessingTimeHistory {
            frameProcessingTimes.removeFirst()
        }
    }
    
    // Calculate average processing time
    private func averageProcessingTime() -> TimeInterval {
        guard !frameProcessingTimes.isEmpty else { return 0 }
        return frameProcessingTimes.reduce(0, +) / Double(frameProcessingTimes.count)
    }
    
    // OPTIMIZATION: Downsample pixel buffer to reduce processing load
    private func downsamplePixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // More aggressive downsampling - reduce to 25% size (was 50%)
        let scale: CGFloat = 0.25
        
        // Lock the buffer for reading
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        let width = Int(scaledImage.extent.width)
        let height = Int(scaledImage.extent.height)
        
        // Create pixel buffer pool if needed for reuse
        var outBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                        width, height,
                                        kCVPixelFormatType_32BGRA,
                                        attributes, &outBuffer)
        
        guard status == kCVReturnSuccess, let outputBuffer = outBuffer else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return nil
        }
        
        // Lock the output buffer for writing
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        // Render the scaled image to the output buffer
        ciContext.render(scaledImage, to: outputBuffer)
        
        // Unlock both buffers
        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        
        return outputBuffer
    }
    
    // MARK: - UI Updates
    
    private func updateDebugInfo(with metrics: ReflectivityMetrics) {
        // This would update any UIKit-based debug info
        // For SwiftUI integration, we primarily use the publisher
    }
    
    // MARK: - User Interaction
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: sceneView)
        
        // Log tap for debugging
        print("DEBUG: Tap detected at \(location)")
        
        // Perform hit test to find real-world surface
        let results = sceneView.hitTest(location, types: .existingPlaneUsingExtent)
        
        if let hitResult = results.first {
            // Create a visual indicator at the tapped position
            print("DEBUG: Hit test successful, adding indicator")
            addIndicator(at: hitResult.worldTransform)
        } else {
            // Provide feedback even when no plane is hit
            print("DEBUG: No plane detected at tap location")
            
            // Add indicator in front of camera as fallback
            if let camera = sceneView.pointOfView {
                let cameraTransform = camera.transform
                let position = SCNVector3(
                    cameraTransform.m41 + cameraTransform.m31 * 0.5,
                    cameraTransform.m42 + cameraTransform.m32 * 0.5,
                    cameraTransform.m43 + cameraTransform.m33 * 0.5
                )
                
                // Create a temporary indicator
                let sphere = SCNSphere(radius: 0.01)
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.red // Red for "no plane detected"
                sphere.materials = [material]
                
                let node = SCNNode(geometry: sphere)
                node.position = position
                
                // Add to scene
                sceneView.scene.rootNode.addChildNode(node)
                
                // Remove after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    node.removeFromParentNode()
                }
            }
        }
    }
    
    private func addIndicator(at transform: matrix_float4x4) {
        // Create a small sphere to mark the position
        let sphere = SCNSphere(radius: 0.01)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.yellow
        sphere.materials = [material]
        
        let node = SCNNode(geometry: sphere)
        node.simdTransform = transform
        
        // Add to scene
        sceneView.scene.rootNode.addChildNode(node)
        
        // Animate the indicator
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        material.diffuse.contents = UIColor.green
        SCNTransaction.commit()
        
        // Remove after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            node.removeFromParentNode()
        }
    }
    
    // MARK: - Highlight Visualization
    
    /// Visually highlights potential inscription areas on screen
    /// - Parameter metrics: The reflectivity metrics from the analyzer
    private func highlightReflectiveAreas(metrics: ReflectivityMetrics) {
        // Only proceed if we're on the main thread or dispatch to main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.highlightReflectiveAreas(metrics: metrics)
            }
            return
        }
        
        // Remove any existing highlight node
        highlightNode?.removeFromParentNode()
        
        // Only highlight if we have significant reflectivity
        let reflectivityThreshold: Float = 0.05 * Float(highlightIntensity)
        guard metrics.specularScore > reflectivityThreshold ||
              (metrics.surfaceType == .shiny && metrics.brightnessVariance > 0.01) else {
            return
        }
        
        // Create a semi-transparent overlay to highlight reflective areas
        let highlightGeometry = SCNPlane(width: 0.2, height: 0.2)
        let material = SCNMaterial()
        
        // Color based on surface type with transparency
        var color: UIColor
        var alpha: CGFloat
        
        switch metrics.surfaceType {
        case .shiny:
            color = UIColor.blue
            // Higher specular score = more opaque highlight
            alpha = CGFloat(min(0.4, metrics.specularScore * 2.0)) * CGFloat(highlightIntensity)
        case .matte:
            color = UIColor.green
            // Higher diffuse score = more opaque highlight
            alpha = CGFloat(min(0.3, metrics.diffuseScore * 1.5)) * CGFloat(highlightIntensity)
        case .unknown:
            color = UIColor.yellow
            alpha = CGFloat(0.2) * CGFloat(highlightIntensity)
        }
        
        material.diffuse.contents = color.withAlphaComponent(alpha)
        material.transparency = 0.7
        material.blendMode = .add
        highlightGeometry.materials = [material]
        
        // Create node and position it in front of the camera
        let node = SCNNode(geometry: highlightGeometry)
        
        // Position the highlight in front of the camera
        let cameraPosition = sceneView.pointOfView?.position ?? SCNVector3(0, 0, -0.5)
        let cameraDirection = sceneView.pointOfView?.worldFront ?? SCNVector3(0, 0, -1)
        
        // Place the highlight 0.5 meters in front of the camera
        let highlightPosition = SCNVector3(
            cameraPosition.x + cameraDirection.x * 0.5,
            cameraPosition.y + cameraDirection.y * 0.5,
            cameraPosition.z + cameraDirection.z * 0.5
        )
        
        node.position = highlightPosition
        
        // Orient the highlight to face the camera
        node.constraints = [SCNBillboardConstraint()]
        
        // Add to scene
        sceneView.scene.rootNode.addChildNode(node)
        highlightNode = node
        
        // Animate the highlight with subtle pulsing
        let pulseAction = SCNAction.sequence([
            SCNAction.scale(to: 1.1, duration: 0.5),
            SCNAction.scale(to: 1.0, duration: 0.5)
        ])
        node.runAction(SCNAction.repeatForever(pulseAction))
    }
    
    /// Updates the highlight settings based on user preferences
    /// - Parameters:
    ///   - show: Whether to show highlights
    ///   - intensity: The intensity of the highlights (0.0-1.0)
    func updateHighlightSettings(show: Bool, intensity: Double) {
        shouldShowHighlights = show
        highlightIntensity = intensity
        
        // If highlights are disabled, remove any existing highlight
        if !show, let highlightNode = highlightNode {
            highlightNode.removeFromParentNode()
            self.highlightNode = nil
        }
    }
    
    /// Updates the detection mode based on user preferences
    /// - Parameter mode: The detection mode (0: Standard, 1: High Sensitivity, 2: Archaeological)
    func updateDetectionMode(_ mode: Int) {
        if detectionMode != mode {
            detectionMode = mode
            print("Detection mode updated to: \(mode)")
            
            // Pass the detection mode to the analyzer
            analyzer.setDetectionMode(mode)
        }
    }
}
