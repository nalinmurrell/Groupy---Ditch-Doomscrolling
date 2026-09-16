import SwiftUI

/// Shown when `Supabase.plist` is still empty. Developer-facing; a shipped
/// build never lands here.
struct SetupNeededScreen: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "server.rack")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                Text("Connect Supabase")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                Text("ChatSnap needs a project URL and anon key before it can sign anyone in.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Create a project at supabase.com")
                    step(2, "Run supabase/schema.sql in the SQL Editor")
                    step(3, "Project Settings → API: copy the URL and anon key")
                    step(4, "Paste both into ChatSnap/Supabase.plist and rebuild")
                }
                .padding(.top, 6)
            }
            .padding(32)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(.white, in: Circle())
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
