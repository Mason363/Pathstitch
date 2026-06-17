import SwiftUI
import AppKit

struct RecentFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumbnail: NSImage?
    var displayName: String
    var modifiedDate: Date
    var fileSizeBytes: Int64
    var isAvailable: Bool
    
    static func == (lhs: RecentFile, rhs: RecentFile) -> Bool {
        return lhs.url == rhs.url && lhs.thumbnail == rhs.thumbnail && lhs.isAvailable == rhs.isAvailable && lhs.modifiedDate == rhs.modifiedDate
    }
}

/// Persists which recent projects the user has explicitly removed (MAS-139).
/// The Spotlight query and AppKit's recent-documents list would otherwise keep
/// re-surfacing a removed file, so removal is recorded here and filtered out on
/// every refresh. Re-opening a file un-hides it. Shared with `WindowManager`.
enum RecentsHiding {
    private static let key = "welcome.hiddenRecentPaths.v1"

    static func hidden() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func hide(_ path: String) {
        var set = hidden()
        set.insert(path)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    static func unhide(_ path: String) {
        var set = hidden()
        guard set.remove(path) != nil else { return }
        if set.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Array(set), forKey: key)
        }
    }
}

@Observable
class WelcomeState {
    var recentFiles: [RecentFile] = []
    var isDraggingOver: Bool = false
    var selectedIndex: Int? = nil
    
    private var metadataQuery: NSMetadataQuery?
    
    init() {
        setupSpotlightQuery()
    }
    
    func refreshRecents() {
        let appKitRecents = NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension == "stch" }
            
        updateList(with: appKitRecents)
        
        // Trigger/restart Spotlight query
        metadataQuery?.stop()
        metadataQuery?.start()
    }
    
    private func setupSpotlightQuery() {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemFSName LIKE '*.stch'")
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)]
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        
        self.metadataQuery = query
    }
    
    @objc private func queryDidFinishGathering(notification: Notification) {
        processQueryResults()
    }
    
    @objc private func queryDidUpdate(notification: Notification) {
        processQueryResults()
    }
    
    private func processQueryResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        
        var urls: [URL] = []
        for i in 0..<query.resultCount {
            if let item = query.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                let url = URL(fileURLWithPath: path)
                urls.append(url)
            }
        }
        
        let appKitRecents = NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension == "stch" }
        
        var allURLs = appKitRecents + urls
        var uniqueURLs: [URL] = []
        var seenPaths = Set<String>()
        
        for url in allURLs {
            let path = url.standardized.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                uniqueURLs.append(url)
            }
        }
        
        // Spotlight queries can return stale/deleted files; filter those out unless in AppKit recents
        let finalURLs = uniqueURLs.filter { url in
            let exists = FileManager.default.fileExists(atPath: url.path)
            let isKitRecent = appKitRecents.contains(where: { $0.standardized.path == url.standardized.path })
            return exists || isKitRecent
        }
        
        updateList(with: finalURLs)
    }
    
    private func updateList(with urls: [URL]) {
        // Drop any projects the user explicitly removed from recents (MAS-139).
        let hidden = RecentsHiding.hidden()
        let targetURLs = Array(urls.filter { !hidden.contains($0.standardized.path) }.prefix(20))
        var newFiles: [RecentFile] = []
        
        for url in targetURLs {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modDate = attrs?[.modificationDate] as? Date ?? Date()
            let size = attrs?[.size] as? Int64 ?? 0
            
            if let existing = self.recentFiles.first(where: { $0.url.standardized.path == url.standardized.path }) {
                var updated = existing
                updated.isAvailable = exists
                updated.modifiedDate = modDate
                updated.fileSizeBytes = size
                newFiles.append(updated)
            } else {
                let file = RecentFile(
                    url: url,
                    thumbnail: nil,
                    displayName: url.deletingPathExtension().lastPathComponent,
                    modifiedDate: modDate,
                    fileSizeBytes: size,
                    isAvailable: exists
                )
                newFiles.append(file)
            }
        }
        
        newFiles.sort(by: { $0.modifiedDate > $1.modifiedDate })
        self.recentFiles = newFiles
        
        if let selected = self.selectedIndex {
            if selected >= newFiles.count {
                self.selectedIndex = newFiles.isEmpty ? nil : newFiles.count - 1
            }
        }
        
        // Spawn async thumbnail loader for available files without thumbnails
        for file in self.recentFiles {
            if file.thumbnail == nil && file.isAvailable {
                Task {
                    if let thumb = await PathstitchThumbnailLoader.loadThumbnail(from: file.url) {
                        await MainActor.run {
                            if let idx = self.recentFiles.firstIndex(where: { $0.id == file.id }) {
                                self.recentFiles[idx].thumbnail = thumb
                            }
                        }
                    }
                }
            }
        }
    }
    
    func selectNext() {
        guard !recentFiles.isEmpty else { return }
        if let current = selectedIndex {
            selectedIndex = min(current + 1, recentFiles.count - 1)
        } else {
            selectedIndex = 0
        }
    }
    
    func selectPrevious() {
        guard !recentFiles.isEmpty else { return }
        if let current = selectedIndex {
            selectedIndex = max(current - 1, 0)
        } else {
            selectedIndex = recentFiles.count - 1
        }
    }
    
    func openSelected() {
        guard let idx = selectedIndex, idx < recentFiles.count else { return }
        let file = recentFiles[idx]
        if file.isAvailable {
            WindowManager.shared.openDocument(url: file.url)
        }
    }

    /// Removes a project from the recents list and remembers the removal so it
    /// doesn't reappear on the next Spotlight/AppKit refresh (MAS-139).
    func removeFromRecents(_ file: RecentFile) {
        RecentsHiding.hide(file.url.standardized.path)
        recentFiles.removeAll { $0.url.standardized.path == file.url.standardized.path }
        if let sel = selectedIndex {
            selectedIndex = recentFiles.isEmpty ? nil : min(sel, recentFiles.count - 1)
        }
    }
}
