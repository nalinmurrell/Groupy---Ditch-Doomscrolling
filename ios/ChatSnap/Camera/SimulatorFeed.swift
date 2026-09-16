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
