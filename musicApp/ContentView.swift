import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Hello, World!")
            .font(.system(size: 48, weight: .bold))
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
    }
}