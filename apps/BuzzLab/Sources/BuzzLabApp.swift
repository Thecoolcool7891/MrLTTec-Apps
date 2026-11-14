import SwiftUI

@main
struct BuzzLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Basics", systemImage: "hand.tap.fill") {
                NavigationStack { BasicsView().navigationTitle("Basics") }
            }
            Tab("Patterns", systemImage: "waveform.path") {
                NavigationStack { PatternsView().navigationTitle("Patterns") }
            }
            Tab("Touch Pad", systemImage: "hand.draw.fill") {
                NavigationStack { TouchPadView().navigationTitle("Touch Pad") }
            }
        }
        .tint(.orange)
    }
}
