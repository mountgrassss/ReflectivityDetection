import Foundation
import SwiftUI

enum SurfaceType: String, Identifiable, CaseIterable {
    case shiny = "Shiny"
    case matte = "Matte"
    case unknown = "Unknown"
    
    var id: String { self.rawValue }
    
    var description: String {
        switch self {
        case .shiny:
            return "Highly reflective surface with specular highlights"
        case .matte:
            return "Diffuse surface with even light distribution"
        case .unknown:
            return "Surface type not determined"
        }
    }
    
    var color: Color {
        switch self {
        case .shiny:
            return Color.blue
        case .matte:
            return Color.green
        case .unknown:
            return Color.gray
        }
    }
    
    var threshold: Float {
        switch self {
        case .shiny:
            return 0.85 // High threshold for specular highlights
        case .matte:
            return 0.4  // Lower threshold for diffuse reflection
        case .unknown:
            return 0.0
        }
    }
}

struct ReflectivityMetrics {
    var specularScore: Float = 0.0
    var diffuseScore: Float = 0.0
    var brightnessVariance: Float = 0.0
    var averageBrightness: Float = 0.0
    var varianceThreshold: Float = 0.0
    var surfaceType: SurfaceType = .unknown
    
    var description: String {
        return """
        Surface Type: \(surfaceType.rawValue)
        Specular Score: \(String(format: "%.2f", specularScore))
        Diffuse Score: \(String(format: "%.2f", diffuseScore))
        Brightness Variance: \(String(format: "%.2f", brightnessVariance))
        Variance Threshold: \(String(format: "%.2f", varianceThreshold))
        Average Brightness: \(String(format: "%.2f", averageBrightness))
        """
    }
}