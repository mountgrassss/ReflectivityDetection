# ReflectivityDetection App

An iOS application for detecting reflective surfaces to identify faint inscriptions on archaeological artifacts using AR technology.

## Project Structure

The project follows a modular architecture with the following components:

### App
- `AppDelegate.swift` - Main application delegate
- `SceneDelegate.swift` - Scene management
- `ReflectivityDetectionApp.swift` - SwiftUI app structure (reference)

### Core
- **AR**
  - `ReflectivityViewController.swift` - AR session management and camera control
- **ImageProcessing**
  - (Future implementation for image enhancement algorithms)
- **InscriptionDetection**
  - `ReflectivityAnalyzer.swift` - Core analysis of reflective surfaces

### UI
- **Views**
  - `ContentView.swift` - Main SwiftUI view
- **ViewModels**
  - `ReflectivityViewModel.swift` - View model for UI updates

### Models
- `SurfaceType.swift` - Data models and metrics

### Utilities
- (Future implementation for helper functions)

### Resources
- **Documentation**
  - (Future implementation for user guides)

## Requirements

- iOS 15.0+
- Xcode 14.0+
- Swift 5.0+
- Device with ARKit support

## Frameworks Used

- SwiftUI
- UIKit
- ARKit
- Vision
- CoreImage
- Combine

## Setup Instructions

1. Open `ReflectivityDetection.xcodeproj` in Xcode
2. Select your development team in the signing settings
3. Choose a target device (must support ARKit)
4. Build and run the application

## Features

- Real-time reflectivity analysis
- Surface type classification
- Metrics visualization
- AR-based detection

## License

Copyright © 2025