import AVFoundation
import SwiftUI

/// The Simulator has no camera hardware, so there's nothing to preview and
/// nothing to capture. This stands in for the live feed there so the actual
/// UI stays developable without a device. `CameraController` only ever turns
/// it on under `#if targetEnvironment(simulator)`, so on a real build this is
/// dead weight the optimizer drops.
struct SimulatorFeed: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: (t / 18).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.42),
                        Color(hue: (t / 26 + 0.4).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.2),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // A slow drift makes it obvious at a glance that the feed is
                // live rather than a frozen placeholder.
                Circle()
                    .fill(.white.opacity(0.06))
                    .frame(width: 320, height: 320)
                    .offset(x: CGFloat(sin(t / 3)) * 90, y: CGFloat(cos(t / 4)) * 140)
                    .blur(radius: 30)

                Text("SIMULATOR FEED")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

extension SimulatorFeed {
    /// A still frame, used as the "photo" when the shutter is tapped.
    @MainActor
    static func still(size: CGSize) -> UIImage? {
        let renderer = ImageRenderer(content: SimulatorFeed().frame(width: size.width, height: size.height))
        renderer.scale = 2
        return renderer.uiImage
    }
}

extension SimulatorFeed {
    /// A short stand-in clip so hold-to-record can be exercised without a
    /// camera: a dozen frames of the feed, written with AVAssetWriter.
    @MainActor
    static func clip() -> URL? {
        let size = CGSize(width: 720, height: 1280)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<12 {
            let renderer = ImageRenderer(content:
                SimulatorFeed().frame(width: size.width, height: size.height)
                    .overlay(Text("\(frame)").font(.system(size: 120, weight: .black)).foregroundStyle(.white.opacity(0.4)))
            )
            guard let cg = renderer.cgImage, let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                ctx.draw(cg, in: CGRect(origin: .zero, size: size))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(5_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 8))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? url : nil
    }
}
