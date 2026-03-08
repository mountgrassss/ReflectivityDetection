import UIKit
import ARKit
import Combine

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
    private let processingInterval: TimeInterval = 0.3

    // Buffer management
    private var bufferMetrics = ARBufferMetrics()
    private let bufferSemaphore = DispatchSemaphore(value: 3)
    private var activeBufferCount = 0

    // Serial processing queue
    private let processingQueue = DispatchQueue(
        label: "com.reflectivity.processing",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )

    // Shared CIContext
    private lazy var ciContext: CIContext = {
        return CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: true,
            .allowLowPower: false
        ])
    }()

    // Frame processing time tracking
    private var frameProcessingTimes: [TimeInterval] = []
    private let maxProcessingTimeHistory = 10

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupARView()
        startARSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if sceneView.session.configuration == nil {
            startARSession()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    // MARK: - Setup

    private func setupARView() {
        sceneView = ARSCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sceneView)

        sceneView.session = session
        session.delegate = self

        let tapGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTap(_:))
        )
        sceneView.addGestureRecognizer(tapGesture)
    }

    private func startARSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isLightEstimationEnabled = true
        configuration.environmentTexturing = .none

        if #available(iOS 13.0, *) {
            configuration.frameSemantics = []
        }

        let needsCalibration = checkIfCalibrationNeeded()
        if !needsCalibration {
            analyzer.loadCalibrationValues()
        }

        let options: ARSession.RunOptions = needsCalibration
            ? [.resetTracking, .removeExistingAnchors]
            : [.removeExistingAnchors]

        // Select optimal video format
        if let format = selectVideoFormat() {
            configuration.videoFormat = format
        }

        session.run(configuration, options: options)
    }

    private func selectVideoFormat() -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats

        // Prefer 60fps with moderate resolution
        if let highFps = formats.first(where: {
            $0.imageResolution.width <= 1280 && $0.framesPerSecond >= 60
        }) {
            return highFps
        }

        // Fall back to 30fps
        return formats.first(where: {
            $0.imageResolution.width <= 1280 && $0.framesPerSecond >= 30
        })
    }

    private func checkIfCalibrationNeeded() -> Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: "ReflectivityDetection.hasBeenCalibrated")
    }

    // MARK: - AR Session Delegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        bufferMetrics.totalFramesReceived += 1

        // Throttle processing
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastProcessedTime >= processingInterval else {
            bufferMetrics.droppedFrames += 1
            return
        }
        lastProcessedTime = currentTime

        // Try to acquire semaphore
        let semaphoreResult = bufferSemaphore.wait(timeout: .now() + 0.01)
        guard semaphoreResult == .success else {
            bufferMetrics.droppedFrames += 1
            return
        }

        activeBufferCount += 1
        bufferMetrics.bufferQueueLength = activeBufferCount

        // Process on dedicated queue
        processingQueue.async { [weak self] in
            autoreleasepool {
                guard let self = self else { return }

                let processStartTime = CACurrentMediaTime()

                // Create CIImage directly from the frame's pixel buffer.
                // CIImage is lazy - it holds a reference without copying
                // pixel data upfront. The actual downsampling happens once
                // in processFrame via the shared CIContext.
                let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
                self.processFrame(ciImage)

                let processDuration = CACurrentMediaTime() - processStartTime
                self.trackFrameProcessingTime(processDuration)

                DispatchQueue.main.async {
                    self.bufferMetrics.framesProcessed += 1
                    self.bufferMetrics.averageProcessingTime =
                        self.averageProcessingTime()
                    self.bufferMetrics.peakProcessingTime =
                        self.frameProcessingTimes.max() ?? 0
                    self.bufferMetricsPublisher.send(self.bufferMetrics)
                    self.activeBufferCount -= 1
                }
                self.bufferSemaphore.signal()
            }
        }
    }

    func session(
        _ session: ARSession,
        didFailWithError error: Error
    ) {
        print("AR Session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // Session interrupted - AR tracking paused
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        startARSession()
    }

    // MARK: - Frame Processing

    private func processFrame(_ ciImage: CIImage) {
        autoreleasepool {
            // Single downsampling step: 25% of original resolution.
            // The analyzer no longer does its own downsampling.
            let scale: CGFloat = 0.25
            let downsampledImage = ciImage.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale)
            )

            // Share the CIContext with the analyzer
            analyzer.setCIContext(ciContext)

            let metrics = analyzer.analyzeFrame(downsampledImage)

            // Add variance threshold to metrics
            let varianceThreshold = getModeSpecificVarianceThreshold()
            var metricsWithThreshold = metrics
            metricsWithThreshold.varianceThreshold = varianceThreshold

            // Highlight reflective areas if enabled
            if shouldShowHighlights {
                highlightReflectiveAreas(metrics: metricsWithThreshold)
            } else if highlightNode != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.highlightNode?.removeFromParentNode()
                    self?.highlightNode = nil
                }
            }

            // Publish metrics to SwiftUI
            DispatchQueue.main.async { [weak self] in
                self?.metricsPublisher.send(metricsWithThreshold)
            }
        }
    }

    private func trackFrameProcessingTime(_ time: TimeInterval) {
        frameProcessingTimes.append(time)
        if frameProcessingTimes.count > maxProcessingTimeHistory {
            frameProcessingTimes.removeFirst()
        }
    }

    private func averageProcessingTime() -> TimeInterval {
        guard !frameProcessingTimes.isEmpty else { return 0 }
        return frameProcessingTimes.reduce(0, +)
            / Double(frameProcessingTimes.count)
    }

    // MARK: - User Interaction

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: sceneView)

        let results = sceneView.hitTest(
            location,
            types: .existingPlaneUsingExtent
        )

        if let hitResult = results.first {
            addIndicator(at: hitResult.worldTransform)
        } else {
            addFallbackIndicator()
        }
    }

    private func addFallbackIndicator() {
        guard let camera = sceneView.pointOfView else { return }

        let cameraTransform = camera.transform
        let position = SCNVector3(
            cameraTransform.m41 + cameraTransform.m31 * 0.5,
            cameraTransform.m42 + cameraTransform.m32 * 0.5,
            cameraTransform.m43 + cameraTransform.m33 * 0.5
        )

        let sphere = SCNSphere(radius: 0.01)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.red
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.position = position
        sceneView.scene.rootNode.addChildNode(node)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            node.removeFromParentNode()
        }
    }

    private func addIndicator(at transform: matrix_float4x4) {
        let sphere = SCNSphere(radius: 0.01)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.yellow
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.simdTransform = transform
        sceneView.scene.rootNode.addChildNode(node)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        material.diffuse.contents = UIColor.green
        SCNTransaction.commit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            node.removeFromParentNode()
        }
    }

    // MARK: - Highlight Visualization

    private func highlightReflectiveAreas(
        metrics: ReflectivityMetrics
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.highlightReflectiveAreas(metrics: metrics)
            }
            return
        }

        highlightNode?.removeFromParentNode()

        let reflectivityThreshold =
            getModeSpecificThreshold() * Float(highlightIntensity)
        let varianceThreshold: Float =
            metrics.varianceThreshold > 0
                ? metrics.varianceThreshold
                : getModeSpecificVarianceThreshold()

        guard metrics.specularScore > reflectivityThreshold
            || (metrics.surfaceType == .shiny
                && metrics.brightnessVariance > varianceThreshold) else {
            return
        }

        let highlightGeometry = SCNPlane(width: 0.2, height: 0.2)
        let material = SCNMaterial()

        let (color, alpha) = highlightColorAndAlpha(for: metrics)

        material.diffuse.contents = color.withAlphaComponent(alpha)
        material.transparency = 0.7
        material.blendMode = .add
        highlightGeometry.materials = [material]

        let node = SCNNode(geometry: highlightGeometry)

        let cameraPosition = sceneView.pointOfView?.position
            ?? SCNVector3(0, 0, -0.5)
        let cameraDirection = sceneView.pointOfView?.worldFront
            ?? SCNVector3(0, 0, -1)

        node.position = SCNVector3(
            cameraPosition.x + cameraDirection.x * 0.5,
            cameraPosition.y + cameraDirection.y * 0.5,
            cameraPosition.z + cameraDirection.z * 0.5
        )

        node.constraints = [SCNBillboardConstraint()]
        sceneView.scene.rootNode.addChildNode(node)
        highlightNode = node

        let pulseAction = SCNAction.sequence([
            SCNAction.scale(to: 1.1, duration: 0.5),
            SCNAction.scale(to: 1.0, duration: 0.5)
        ])
        node.runAction(SCNAction.repeatForever(pulseAction))
    }

    private func highlightColorAndAlpha(
        for metrics: ReflectivityMetrics
    ) -> (UIColor, CGFloat) {
        let intensity = CGFloat(highlightIntensity)

        switch metrics.surfaceType {
        case .shiny:
            let minAlpha: CGFloat = 0.5
            let alpha = max(
                minAlpha,
                CGFloat(min(0.4, metrics.specularScore * 2.0))
            ) * intensity
            return (.green, alpha)

        case .matte:
            let minAlpha: CGFloat = 0.12
            let alpha = max(
                minAlpha,
                CGFloat(min(0.3, metrics.diffuseScore * 1.5))
            ) * intensity
            return (.blue, alpha)

        case .unknown:
            let alpha = max(CGFloat(0.1), CGFloat(0.2)) * intensity
            return (.yellow, alpha)
        }
    }

    // MARK: - Settings

    func updateHighlightSettings(show: Bool, intensity: Double) {
        shouldShowHighlights = show
        highlightIntensity = intensity

        if !show {
            highlightNode?.removeFromParentNode()
            highlightNode = nil
        }
    }

    func updateDetectionMode(_ mode: Int) {
        if detectionMode != mode {
            detectionMode = mode
            analyzer.setDetectionMode(mode)
        }
    }

    private func getModeSpecificThreshold() -> Float {
        switch detectionMode {
        case 1: return 0.08
        case 2: return 0.20
        default: return 0.15
        }
    }

    private func getModeSpecificVarianceThreshold() -> Float {
        switch detectionMode {
        case 1: return 0.003
        case 2: return 0.006
        default: return 0.005
        }
    }
}
