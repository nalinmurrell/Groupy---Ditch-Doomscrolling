import SwiftUI
import UIKit

/// Snapchat's viewfinder: a 9:16 card tucked under the status bar, top corners rounded,
/// with black around it — not the whole of a tall iPhone screen. Whatever
/// goes inside (the live preview, the review) shares the frame, and the
/// camera crops photos to the card's exact shape so what you saw is what's
/// sent.
struct CameraCard<Content: View>: View {
    @EnvironmentObject private var camera: CameraController
    @ViewBuilder let content: () -> Content

    static var aspect: CGFloat { 9.0 / 16.0 }

    var body: some View {
        GeometryReader { geo in
            // The window's insets, not SwiftUI's: a screen presented while
            // the photo picker is still closing gets a zero top safe area
            // from SwiftUI and the card slid up under the status bar.
            let insets = Self.windowInsets ?? UIEdgeInsets(
                top: geo.safeAreaInsets.top, left: 0, bottom: geo.safeAreaInsets.bottom, right: 0
            )
            let width = geo.size.width
            let available = geo.size.height - insets.top - insets.bottom
            // Full 9:16 where it fits (every current iPhone); on a short
            // screen it's as tall as there's room for, and photos follow.
            let height = min(width / Self.aspect, available)
            content()
                .frame(width: width, height: height)
                // Rounded along the top only; the bottom edge meets the tab bar.
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 22, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 22,
                    style: .continuous
                ))
                .padding(.top, insets.top)
                .frame(maxHeight: .infinity, alignment: .top)
                .onAppear { camera.viewfinderAspect = width / height }
                .onChange(of: width / height) { _, aspect in camera.viewfinderAspect = aspect }
        }
        .ignoresSafeArea()
    }

    private static var windowInsets: UIEdgeInsets? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets
    }
}
