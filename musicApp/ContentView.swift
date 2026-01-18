import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            Text("Hello, World!")
                .font(.largeTitle)
                .foregroundColor(.black)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}