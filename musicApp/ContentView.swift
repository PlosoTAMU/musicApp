//
//  ContentView.swift
//  musicApp
//
//  Created by TP on 1/17/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            Text("Hello, World!")
                .font(.largeTitle)
                .foregroundStyle(.black)
        }
    }
}

#Preview {
    ContentView()
}