import SwiftUI

/// The top of the Chat and Friends tabs: your avatar exactly where it sits
/// on the camera (40pt, 20pt in, 12pt under the status bar area), with the
/// page title centred on the same line. Replaces the navigation bar, whose
/// own avatar slot sat smaller and higher than the camera's.
struct TabHeader<Below: View>: View {
    let title: String
    @ViewBuilder var below: () -> Below

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                HStack {
                    ProfileButton()
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            below()
        }
        .padding(.bottom, 8)
        .background(Color.black)
    }
}

extension TabHeader where Below == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A search field in the style of the system one, for headers that aren't
/// navigation bars.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.45))
                TextField("", text: $text, prompt: Text(prompt).foregroundColor(.white.opacity(0.45)))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.quiet)
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Like the system search bar: the way out while typing.
            if isFocused {
                Button("Cancel") {
                    text = ""
                    isFocused = false
                }
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .buttonStyle(.quiet)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}
