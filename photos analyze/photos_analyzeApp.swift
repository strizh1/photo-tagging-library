//
//  photos_analyzeApp.swift
//  photos analyze
//

import SwiftUI
import SwiftData

@main
struct photos_analyzeApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PhotoRecord.self,
            ScannedFolder.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        WindowGroup("Photo", id: "viewer", for: ViewerItem.self) { $item in
            if let item {
                PhotoViewer(item: item)
            }
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            MergedTagsSettings()
        }
    }
}
