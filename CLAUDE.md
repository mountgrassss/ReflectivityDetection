# ReflectivityDetector

iOS AR application for archaeological inscription detection through real-time reflectivity analysis using ARKit.

## Quick Start

```bash
# Open in Xcode
open ReflectivityDetection.xcodeproj

# Build: Cmd+B (requires iOS 15.0+ target device with ARKit)
# Run: Cmd+R (must run on physical device - ARKit not available in simulator)
```

## Architecture

**Pattern:** MVVM + Reactive (Combine) with UIViewRepresentable bridge

```
SwiftUI (ContentView) → ReflectivityViewModel (ObservableObject)
                          ↕ Combine Publishers
                        ReflectivityViewController (ARKit session)
                          → ReflectivityAnalyzer (detection algorithms)
```

### Key Files

| File | Purpose |
|------|---------|
| `ReflectivityDetection/Core/AR/ReflectivityViewController.swift` | AR session management, frame capture, buffer control |
| `ReflectivityDetection/Core/InscriptionDetection/ReflectivityAnalyzer.swift` | 6-stage reflectivity detection pipeline |
| `ReflectivityDetection/UI/ViewModels/ReflectivityViewModel.swift` | State management, calibration, settings persistence |
| `ReflectivityDetection/UI/Views/ContentView.swift` | Main SwiftUI interface with AR overlay |
| `ReflectivityDetection/Models/SurfaceType.swift` | SurfaceType enum + ReflectivityMetrics struct |
| `ReflectivityDetection/Models/ARBufferMetrics.swift` | AR buffer performance tracking |

## Tech Stack

- **Language:** Swift 5.0+
- **UI:** SwiftUI + UIKit (hybrid via UIViewRepresentable)
- **Frameworks:** ARKit, SceneKit, Vision, CoreImage, Combine
- **Dependencies:** None (pure native iOS)
- **Build:** Xcode project (.xcodeproj)
- **Min Target:** iOS 15.0

## Detection Modes

| Mode | Downsampling | Specular Threshold | Use Case |
|------|-------------|-------------------|----------|
| Standard (0) | 25% | 0.9 | General reflectivity |
| High Sensitivity (1) | 40% | 0.75 | Faint inscriptions |
| Archaeological (2) | 30% | Optimized | Ancient materials |

## Data Flow

1. ARKit frame → `ReflectivityViewController.session(didUpdate:)`
2. Buffer semaphore (max 3) → throttle (300ms interval)
3. `ReflectivityAnalyzer.analyzeFrame()` → 6-stage pipeline
4. `metricsPublisher.send()` → Combine → ViewModel
5. `@Published` updates → SwiftUI re-render

## Calibration System

- Collects 10 samples → calculates baseline → stores adjustment offsets
- Auto-detects environment changes (>50% deviation) → prompts recalibration
- Persisted via UserDefaults

## Performance Notes

- Frame throttling: 300ms minimum between processing
- Semaphore limit: max 3 concurrent buffer operations
- Shared CIContext (reused, not recreated)
- Autoreleasepool wrapping for buffer operations
- Sparse pixel sampling (stride 32-64)

## Conventions

- Follow Swift API Design Guidelines
- MVVM with Combine for reactive data flow
- Use `@Published` for observable state
- Commit messages: `<type>: <description>` (feat, fix, refactor, etc.)
