import QuickLookThumbnailing
import CoreGraphics
import Cocoa

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let fileURL = request.fileURL

        // Per-format Finder thumbnail toggle (MAS-155). When off, decline so
        // Finder shows the generic file icon instead.
        guard QuickLookPreviewSettings.isEnabled(forExtension: fileURL.pathExtension) else {
            handler(nil, nil)
            return
        }

        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        // Render the file (.stch embedded preview, or freshly-framed DXF) to a
        // black-on-white bitmap sized generously, then blit it aspect-fit into the
        // thumbnail context so it stays crisp when downscaled to a Finder icon.
        let renderSize = CGSize(width: 1200, height: 800)
        // STEP files get the lightweight isometric point-cloud preview (MAS-63);
        // everything else uses the DXF/.stch renderer.
        let ext = fileURL.pathExtension.lowercased()
        let image: CGImage?
        if ext == "step" || ext == "stp" {
            image = renderStepToImage(url: fileURL, size: renderSize)
        } else {
            image = renderFileToImage(url: fileURL, size: renderSize)
        }
        guard let image = image else {
            handler(nil, nil)
            return
        }

        let reply = QLThumbnailReply(contextSize: request.maximumSize) { context in
            let rect = CGRect(origin: .zero, size: request.maximumSize)
            let imgSize = CGSize(width: image.width, height: image.height)
            let scale = min(rect.width / imgSize.width, rect.height / imgSize.height)
            let target = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
            let targetRect = CGRect(
                x: (rect.width - target.width) / 2,
                y: (rect.height - target.height) / 2,
                width: target.width,
                height: target.height
            )
            context.draw(image, in: targetRect)
            return true
        }

        handler(reply, nil)
    }
}
