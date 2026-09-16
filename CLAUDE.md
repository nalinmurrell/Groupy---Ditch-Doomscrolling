# ChatSnap

Snapchat-style app with **group chat as the whole point**. Opens straight to the
camera; shoot → pick people → it lands in their thread. No stories, no discover,
no fluff. One person's project (Nalin, a WGU software engineering student), so
optimise for learning and momentum, not enterprise ceremony.

## Layout

    ios/        SwiftUI app (Mac only — Xcode 26). Working, verified in Simulator.
    android/    Kotlin + Jetpack Compose app. NOT STARTED — Windows is the Android machine.
    supabase/   Shared backend: schema.sql (run once in the SQL editor) + SETUP.md.

Both apps are thin clients over the same Supabase project. **The schema and its
row-level-security policies are the authorization layer** — the apps use the
public anon key, so anything not allowed by a policy is not allowed, full stop.

## Backend (Supabase)

- Project: `https://xbvmwfvriwhtrotefirx.supabase.co`
- Config for iOS lives in `ios/ChatSnap/Supabase.plist` (URL + anon key). The anon
  key is a public client key by design and is committed. The `service_role` key
  must NEVER go in either app.
- Auth: email + password. "Confirm email" is OFF in the dashboard for development.
  Turn it back on (and add Sign in with Apple / Google) before shipping.
- Tables: `profiles`, `friendships` (directional, no request/accept yet),
  `conversations` (+ `is_group`, `name`), `conversation_members`, `messages`
  (`kind` text|photo, `body`, `photo_path`). Storage bucket `snaps`, private, path
  `snaps/<conversation_id>/<uuid>.jpg` so membership gates the file.
- Helpers: `is_member(cid)` (security definer, used by policies),
  `get_or_create_dm(other_user)` RPC, `handle_new_user()` trigger that creates the
  profile row from sign-up metadata (`username`, `display_name`).
- Realtime is enabled on `messages`; clients subscribe to inserts.
- A leftover probe account `probe-1789526196@chatsnap-probe.io` exists from
  debugging — delete it under Authentication → Users.

## iOS app — state as of 2026-09-16

Verified working in the Simulator: onboarding (welcome → account → camera
priming), three-tab shell (Chat | Camera | Friends; camera is the default centre
pane, swipe either way), shutter → review → Send To picker, DM threads with text
and photo bubbles, friend search/add/remove, sign-out.

Verified against the live backend: sign-up creates the auth user AND the profile
row (trigger works). Friend search hits `profiles`.

**In flight / unverified:** the app was originally built with code signing
disabled, and the Supabase SDK stores the session in the Keychain, which the
Simulator refuses for unsigned binaries. Symptom was "Cannot coerce the result to
a single JSON object" on the camera step (requests going out as anon) and the
session not surviving relaunch. Fix applied in `ios/project.yml`
(`CODE_SIGN_IDENTITY: "-"`, ad-hoc) and it builds, but **nobody has yet confirmed
sign-in → camera step → shell works and persists across relaunch**. Check that
first when back on the Mac.

Not yet built anywhere: group creation UI, push notifications, read receipts
(`isOpened` was dropped when moving to Supabase), Sign in with Apple, ephemeral
"tap to view" snaps (photos are plain inline thumbnails for now).

### Building iOS (Mac)

    cd ios && xcodegen generate
    xcodebuild -project ChatSnap.xcodeproj -scheme ChatSnap -destination 'id=<sim udid>' -derivedDataPath build build
    xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/ChatSnap.app
    xcrun simctl privacy booted grant camera com.chatsnap.app   # reset by reboots/uninstalls
    xcrun simctl launch booted com.chatsnap.app

The `.xcodeproj` is generated and gitignored; edit `project.yml`, not the project.
The Simulator has no camera; `SimulatorFeed.swift` draws a stand-in behind
`#if targetEnvironment(simulator)`. A real iPhone is needed to see a real feed
(free Apple ID + Xcode works; builds expire after 7 days).

Mac-specific quirks: the Claude Code iOS Simulator integration fails until
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` is run (needs
the user's password). Tap injection isn't available either (no AppleScript
assistive access), so screens behind interaction were verified by temporarily
patching a driver into a view's `.task`, screenshotting, then reverting.

## Android app — plan (Windows)

Native Kotlin + Jetpack Compose, CameraX, `supabase-kt` (official Kotlin SDK:
postgrest, auth, storage, realtime modules). Mirror the iOS structure and
behaviour one for one — same three tabs, same flows, same Supabase tables. Put
the URL and anon key in `android/local.properties` or a `BuildConfig` field.
Needs Android Studio (or command-line SDK) + JDK 17/21; Gradle does not like
JDK 26. Target a recent minSdk (26+) — CameraX and Compose are much simpler
without legacy support.

Why native rather than cross-platform: iOS was already built native and the
user chose it deliberately; Kotlin lines up with the Java-heavy WGU curriculum;
and a camera-first app benefits from native camera APIs on both sides. The
cost is two UIs to keep in step. If that becomes painful, Kotlin Multiplatform
could share the data layer (`supabase-kt` supports it) while keeping both UIs.

## Working agreements

- Keep the app free of fluff. Every screen should earn its place.
- Verify in a simulator/emulator before reporting done; screenshots beat claims.
- Test-only driver code never ships: patch, verify, revert, confirm clean.
- Don't seed fake data into the real backend without saying so and how to remove it.
