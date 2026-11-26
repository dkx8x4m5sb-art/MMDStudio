//
//  MMDStudioApp.swift
//  MMD Studio
//
//  App 入口与全局环境对象。
//

import SwiftUI

@main
struct MMDStudioApp: App {
    @StateObject private var store = MMDStore()

    init() {
        MMDLog.shared.info("MMDStudio launched, version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.25, green: 0.82, blue: 0.9))
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: MMDStore

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .onOpenURL { url in
            MMDLog.shared.info("Open URL: \(url.lastPathComponent)")
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try store.importModel(from: url)
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
