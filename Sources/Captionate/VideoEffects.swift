import Foundation
import AVFoundation
import CoreImage

/// Colour looks and picture adjustments, done with Core Image. The same filter chain drives the live
/// preview (as the player item's video composition) and the export.
enum VideoEffects {
    static func apply(_ adjustments: VideoAdjustments, to source: CIImage) -> CIImage {
        let extent = source.extent
        var image = source

        func filter(_ name: String, _ params: [String: Any]) {
            guard let f = CIFilter(name: name) else { return }
            f.setValue(image, forKey: kCIInputImageKey)
            for (k, v) in params { f.setValue(v, forKey: k) }
            if let out = f.outputImage { image = out }
        }

        // Look first, then the user's fine-tuning on top.
        var warmth = adjustments.warmth
        var saturation = adjustments.saturation
        var contrast = adjustments.contrast
        switch adjustments.look {
        case .none: break
        case .vivid:
            filter("CIVibrance", ["inputAmount": 0.6])
            contrast *= 1.06
        case .warm: warmth += 0.45
        case .cool: warmth -= 0.45
        case .cinematic:
            saturation *= 0.85
            contrast *= 1.12
            warmth += 0.15
        case .vintage: filter("CIPhotoEffectInstant", [:])
        case .fade: filter("CIPhotoEffectFade", [:])
        case .chrome: filter("CIPhotoEffectChrome", [:])
        case .mono: filter("CIPhotoEffectMono", [:])
        case .noir: filter("CIPhotoEffectNoir", [:])
        }

        if adjustments.brightness != 0 || contrast != 1 || saturation != 1 {
            filter("CIColorControls", [kCIInputBrightnessKey: adjustments.brightness,
                                       kCIInputContrastKey: contrast,
                                       kCIInputSaturationKey: saturation])
        }
        if warmth != 0 {
            let w = CGFloat(max(-1, min(1, warmth))) * 0.12
            filter("CIColorMatrix", ["inputRVector": CIVector(x: 1 + w, y: 0, z: 0, w: 0),
                                     "inputGVector": CIVector(x: 0, y: 1 + w * 0.2, z: 0, w: 0),
                                     "inputBVector": CIVector(x: 0, y: 0, z: 1 - w, w: 0)])
        }
        if adjustments.sharpen > 0 {
            filter("CISharpenLuminance", [kCIInputSharpnessKey: adjustments.sharpen * 0.8])
        }
        if adjustments.vignette > 0 {
            filter("CIVignette", [kCIInputIntensityKey: adjustments.vignette * 1.6,
                                  kCIInputRadiusKey: 1.6])
        }
        return image.cropped(to: extent)
    }

    /// A video composition that runs the filter chain on every frame, or nil when nothing is changed.
    static func composition(for asset: AVAsset, adjustments: VideoAdjustments) -> AVVideoComposition? {
        guard !adjustments.isIdentity else { return nil }
        return AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage.clampedToExtent()
            let output = apply(adjustments, to: source).cropped(to: request.sourceImage.extent)
            request.finish(with: output, context: nil)
        }
    }

    /// Writes a graded copy of the video (same length, all tracks), used as the source of the caption export.
    static func render(_ asset: AVAsset, adjustments: VideoAdjustments, to url: URL,
                       progress: @escaping (Double) -> Void) async throws {
        guard let composition = composition(for: asset, adjustments: adjustments),
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoExportError.sessionFailed("couldn't apply the video look")
        }
        session.videoComposition = composition
        session.outputURL = url
        session.outputFileType = .mov
        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        ticker.cancel()
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw CancellationError()
        default: throw VideoExportError.sessionFailed(session.error?.localizedDescription ?? "video look failed")
        }
    }
}
