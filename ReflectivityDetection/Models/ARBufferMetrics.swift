import Foundation

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