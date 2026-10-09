import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encode the existing raster, without an intermediate TIFF and its decoded copy.
/// AppKit image selection stays on the main actor; PNG compression runs off it.
enum CapturePNG {
    enum Failure:LocalizedError {
        case unreadableImage,encodingFailed
        var errorDescription:String? { self == .unreadableImage ? "截图位图不可读" : "截图编码失败" }
    }
    @MainActor
    static func encode(_ image:NSImage) async throws -> Data {
        try Task.checkCancellation()
        guard let raster = image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw Failure.unreadableImage }
        let size = image.size
        guard size.width.isFinite,size.height.isFinite,size.width > 0,size.height > 0 else { throw Failure.unreadableImage }
        // CGImage contains pixels but not NSImage's point size. Keep Retina DPI so
        // reopening the PNG has the same logical dimensions and 100% preview scale.
        let dpiWidth = Double(raster.width)*72/size.width, dpiHeight = Double(raster.height)*72/size.height
        let worker = Task.detached(priority:.userInitiated) { () throws -> Data in
            try Task.checkCancellation()
            return try autoreleasepool {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw Failure.encodingFailed }
                CGImageDestinationAddImage(destination,raster,[kCGImagePropertyDPIWidth:dpiWidth,kCGImagePropertyDPIHeight:dpiHeight] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
                try Task.checkCancellation()
                return data as Data
            }
        }
        return try await withTaskCancellationHandler {
            let data = try await worker.value
            try Task.checkCancellation()
            return data
        } onCancel: { worker.cancel() }
    }
}
