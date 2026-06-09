import QuickLookThumbnailing
import ZIPFoundation
import Cocoa

class ThumbnailProvider: QLThumbnailProvider {
    
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let fileURL = request.fileURL
        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let archive = Archive(url: fileURL, accessMode: .read),
              let entry = archive["preview.png"] else {
            handler(nil, nil)
            return
        }
        
        var imgData = Data()
        do {
            _ = try archive.extract(entry, consumer: { chunk in
                imgData.append(chunk)
            })
            
            guard let image = NSImage(data: imgData) else {
                handler(nil, nil)
                return
            }
            
            let reply = QLThumbnailReply(contextSize: request.maximumSize) { context in
                let rect = CGRect(origin: .zero, size: request.maximumSize)
                
                let imgSize = image.size
                let aspectWidth = rect.width / imgSize.width
                let aspectHeight = rect.height / imgSize.height
                let scale = min(aspectWidth, aspectHeight)
                
                let targetSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
                let targetRect = CGRect(
                    x: (rect.width - targetSize.width) / 2,
                    y: (rect.height - targetSize.height) / 2,
                    width: targetSize.width,
                    height: targetSize.height
                )
                
                if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    context.draw(cgImage, in: targetRect)
                    return true
                }
                return false
            }
            
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
