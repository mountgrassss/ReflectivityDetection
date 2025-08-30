import SwiftUI

// Note: This file is kept for reference but the actual app entry point
// is now the AppDelegate class marked with @main
struct ReflectivityDetectionApp: App {
    @State private var isShowingSplash = true
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .statusBar(hidden: true)
                    .preferredColorScheme(.dark) // Better for AR visualization
                
                // Splash screen overlay
                if isShowingSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.5), value: isShowingSplash)
                        .onAppear {
                            // Dismiss splash after delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation {
                                    isShowingSplash = false
                                }
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Splash Screen View
struct SplashScreenView: View {
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 80))
                    .foregroundColor(.white)
                
                Text("Reflectivity Detection")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Archaeological Inscription Analysis")
                    .font(.title3)
                    .foregroundColor(.gray)
            }
        }
    }
}