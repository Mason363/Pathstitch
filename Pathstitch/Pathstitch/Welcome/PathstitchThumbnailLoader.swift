import Cocoa
import ZIPFoundation

struct PathstitchThumbnailLoader {
    private static var cache = NSCache<NSString, NSImage>()
    
    static func loadThumbnail(from url: URL) async -> NSImage? {
        let pathKey = url.path as NSString
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modDate = attrs?[.modificationDate] as? Date ?? Date()
        
        let cacheKey = "\(url.path)_\(modDate.timeIntervalSince1970)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        
        guard let archive = Archive(url: url, accessMode: .read) else {
            return nil
        }
        
        guard let entry = archive["preview.png"] else {
            return nil
        }
        
        var imgData = Data()
        do {
            _ = try archive.extract(entry, consumer: { chunk in
                imgData.append(chunk)
            })
            if let image = NSImage(data: imgData) {
                cache.setObject(image, forKey: cacheKey)
                return image
            }
        } catch {
            // Ignore extraction errors
        }
        return nil
    }
}
