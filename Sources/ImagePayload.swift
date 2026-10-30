import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// An image prepared for sending to an AI model.
struct ChatImage {
    let data: Data
    let mimeType: String
    let pixelSize: CGSize

    var base64: String { data.base64EncodedString() }

    /// Downscales to `maxSide` (models resize larger images anyway) and re-encodes as JPEG,
    /// flattening transparency onto white. Respects EXIF orientation.
    static func load(from url: URL, maxSide: CGFloat = 1568) -> ChatImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ChatImage(data: data as Data, mimeType: "image/jpeg", pixelSize: rect.size)
    }
}

/// On-device description of an image (text it contains, what it shows), for models that can't see images.
enum ImageDescriber {
    static func describe(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary) else { return "(The image could not be read.)" }

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.automaticallyDetectsLanguage = true
        let labels = VNClassifyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([text, labels, faces])

        var lines = ["Image size: \(image.width)×\(image.height) (as analyzed)."]
        let topLabels = (labels.results ?? [])
            .filter { $0.confidence > 0.25 }
            .prefix(10)
            .map { "\($0.identifier.replacingOccurrences(of: "_", with: " ")) (\(Int($0.confidence * 100))%)" }
        if !topLabels.isEmpty { lines.append("Detected contents: " + topLabels.joined(separator: ", ") + ".") }
        let faceCount = faces.results?.count ?? 0
        if faceCount > 0 { lines.append("Faces detected: \(faceCount).") }
        let recognized = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        lines.append(recognized.isEmpty ? "No text found in the image." : "Text in the image:\n" + recognized.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }
}
