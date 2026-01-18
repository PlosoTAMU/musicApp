import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            // Fills the entire background with white, including safe areas
            Color.white
                .ignoresSafeArea()

            Text("Hello, World!")
                .font(.largeTitle)
                // .foregroundColor is the classic modifier, fully compatible with iOS 16
                .foregroundColor(.black)
        }
    }
}

// This is the older, but still perfectly valid, way to create a preview
// It's required when your code needs to be compatible with pre-iOS 17 targets
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}