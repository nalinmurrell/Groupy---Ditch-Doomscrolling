import SwiftUI

/// Anything with a name and a handle can wear an avatar — you or a friend.
protocol AvatarRepresentable {
    var displayName: String { get }
    var username: String { get }
}

extension AvatarRepresentable {
    var initials: String {
        let letters = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return letters.isEmpty ? "?" : letters
    }

    /// Stable per-person colour. Swift's `hashValue` is seeded per process, so
    /// it would repaint every avatar on each launch — this doesn't.
    var hue: Double {
        let sum = username.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }
        return Double(sum % 360) / 360
    }
}

struct Avatar: View {
    let subject: any AvatarRepresentable
    var size: CGFloat = 50

    var body: some View {
        Circle()
            .fill(Color(hue: subject.hue, saturation: 0.5, brightness: 0.7))
            .frame(width: size, height: size)
            .overlay {
                Text(subject.initials)
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}
