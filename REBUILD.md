# Rebuilding the Bai Tracker iOS app from this source folder

This folder is the Swift **source** of the Bai Tracker iOS app, exported as a
zip from the original developer's Mac. The zip did not include Xcode's project
file (`Bai-Tracker.xcodeproj`), which holds the bundle identifier, signing
team and package dependency list.

> **Status (2026-09-17):** `Bai-Tracker.xcodeproj` has been recreated in this
> folder and **verified**: with Xcode 16.2 it resolves packages (Amplify
> 2.61.0, GoogleMaps 9.4.0 — pinned in
> `Bai-Tracker.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`)
> and builds successfully for the iOS Simulator SDK with only pre-existing
> warnings. Steps 1–5 below are already done and are kept only as a
> reference. **Start at step 6**: open `Bai-Tracker.xcodeproj`, set your Team
> and bundle ID, then build and run on a phone.
>
> On the first build inside Xcode you will get a **"Trust & Enable"** prompt
> for the `SmithyCodeGeneratorPlugin` build-tool plugin (part of Amplify's
> AWS SDK dependency). Click **Trust & Enable**; the build cannot proceed
> without it.

Time needed: about an hour on a Mac with Xcode 15 or newer (mostly package
resolution and signing).

## What is here

| Item | Purpose |
|---|---|
| `Bai-Tracker/*.swift` (15 files) | All app code. UI is built in code — there are no storyboards to recover. |
| `Bai-Tracker/Info.plist` | Permission strings (camera, photos, mic, location), scene manifest, launch screen. |
| `Bai-Tracker/Assets.xcassets` | App icon and the `bai` logo image. |
| `Bai-Tracker/bai-eng.png`, `category.csv` | Bundle resources loaded at runtime. |
| `Bai-Tracker/amplify_outputs.json` | AWS backend config (AppSync, Cognito, S3). Same backend as the web app. |
| `Bai-Tracker/Base.lproj` | Empty — safe to ignore. |

Third-party dependencies (from the `import` statements):

| Package | Products used |
|---|---|
| `https://github.com/aws-amplify/amplify-swift` | `Amplify`, `AWSCognitoAuthPlugin`, `AWSAPIPlugin`, `AWSS3StoragePlugin` |
| `https://github.com/googlemaps/ios-maps-sdk` | `GoogleMaps` |

Everything else (`UIKit`, `AVFoundation`, `AVKit`, `PhotosUI`, `CoreLocation`,
`UniformTypeIdentifiers`) ships with iOS.

## What the generated project contains

- One target, `Bai-Tracker` (iOS app, iPhone + iPad, **deployment target iOS
  16.0** — the code uses `UIButton.Configuration`, which needs 15+, and the
  Google Maps SDK 9.x also needs 15+).
- All 15 `.swift` files in **Compile Sources**; `Assets.xcassets`,
  `bai-eng.png`, `category.csv`, `amplify_outputs.json` in **Copy Bundle
  Resources**.
- `INFOPLIST_FILE = Bai-Tracker/Info.plist`, `GENERATE_INFOPLIST_FILE = NO`.
- Packages: `amplify-swift` (≥ 2.0.0, up to next major) with products
  `Amplify`, `AWSCognitoAuthPlugin`, `AWSAPIPlugin`, `AWSS3StoragePlugin`;
  `ios-maps-sdk` (≥ 9.0.0, up to next major) with `GoogleMaps`.
- Automatic signing, **Team left empty** (set it in step 6).
- **Bundle ID placeholder `com.bai-eng.tracker`** — change it to the real one
  from App Store Connect if you are updating the TestFlight app (step 6).
- Version 1.0, build 6 (matches `Info.plist`). Bump the build before each
  TestFlight upload.
- A shared scheme `Bai-Tracker`, so `xcodebuild -scheme Bai-Tracker` works
  from the command line too.

### Building from the command line

```
xcodebuild build -project Bai-Tracker.xcodeproj -scheme Bai-Tracker \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

`-skipPackagePluginValidation` is the CLI equivalent of the "Trust & Enable"
click. Xcode 16.2 was used; Xcode 16.3+ needs macOS 15.

## Steps

### 1. Create an empty project

1. Xcode → **File → New → Project…** → **iOS → App** → Next.
2. Product Name: `Bai-Tracker`. Interface: **Storyboard** (not SwiftUI — this
   gives an `AppDelegate`-based template). Language: **Swift**. Untick tests.
3. Save it somewhere sensible (see "Put it in git" below).

### 2. Remove the template files

In the Project navigator, delete these (choose **Move to Trash**):

- `ViewController.swift`
- `SceneDelegate.swift`
- `Main.storyboard`
- `Assets.xcassets`
- `Info.plist` (if shown as a file; newer Xcode templates may not show one)

### 3. Add the source

1. In Finder, open this folder's `Bai-Tracker/` directory.
2. Select **everything inside it** and drag it onto the `Bai-Tracker` group in
   Xcode's Project navigator.
3. In the dialog: tick **Copy items if needed**, choose **Create groups**, and
   make sure the `Bai-Tracker` target is ticked. Click Finish.
4. Verify resources are in the target: select the target → **Build Phases →
   Copy Bundle Resources** should list `bai-eng.png`, `category.csv`,
   `amplify_outputs.json` and `Assets.xcassets`. Add any that are missing with
   the `+` button.

### 4. Point the target at the imported Info.plist

1. Select the project → target `Bai-Tracker` → **Build Settings**.
2. Search `Info.plist File` and set it to `Bai-Tracker/Info.plist`.
3. Search `Generate Info.plist File` and set it to **No**.
4. Still in the target, open the **Info** tab and confirm the permission
   strings (Camera, Photo Library, Microphone, Location When In Use) are shown.
   The imported plist already declares `UIApplicationSceneManifest` with
   multiple scenes disabled, which is what the `AppDelegate`-only setup needs.

### 5. Add the packages

1. **File → Add Package Dependencies…**
2. Paste `https://github.com/aws-amplify/amplify-swift`, choose
   **Up to Next Major Version**, Add Package. When asked which products to add
   to the target, tick exactly: `Amplify`, `AWSCognitoAuthPlugin`,
   `AWSAPIPlugin`, `AWSS3StoragePlugin`.
3. Repeat with `https://github.com/googlemaps/ios-maps-sdk` and tick
   `GoogleMaps`.
4. Package resolution takes a few minutes the first time.

### 6. Signing

1. Target → **Signing & Capabilities**.
2. Tick **Automatically manage signing** and pick your **Team** (your Apple
   ID, or the company's Apple Developer team — see "Accounts" below).
3. Set **Bundle Identifier**:
   - **To update the existing TestFlight app in place** (the normal case — see
     "TestFlight" below): use the *exact* bundle ID shown in App Store Connect
     → Apps → Bai-Tracker → App Information, and pick that same team.
   - **Starting fresh under a new team**: choose something you own, e.g.
     `com.bai-eng.tracker` (see "Existing installs").

### 7. Build and run

1. Product → **Build** (⌘B). Fix any red errors before continuing; warnings are
   fine.
2. Plug in an iPhone, choose it in the run-destination menu, press **Run**
   (⌘R). First time: on the phone go to **Settings → General → VPN & Device
   Management** and trust the developer certificate, then run again.
3. Sign in with a Bai Tracker account, pick or create a project, confirm the
   map loads and points appear.

## Things to know

### Accounts

- A **free** Apple ID can install on your own phone, but the app stops
  launching 7 days after install and only works on a handful of devices.
- The **Apple Developer Program** ($99/yr, company enrollment recommended)
  removes the 7-day limit and enables **TestFlight**, which is the right way to
  distribute to a field team: Xcode → Product → Archive → Distribute →
  TestFlight, then testers install from the TestFlight app.

### TestFlight (updating the app already on people's phones)

The app is currently distributed through TestFlight, so new builds can be
pushed to every installed phone as in-place updates — provided you upload
under the **same team and bundle ID** as the previous builds.

1. Open the TestFlight app on an iPhone that has Bai-Tracker; the developer /
   team name is shown under the app title. If it is the company team, sign in
   at appstoreconnect.apple.com with the team's Apple ID (or get added under
   *Users and Access* with the **App Manager** role). If it is the intern's
   personal team, ask them to add you as App Manager or transfer the app
   (App Information → Transfer App); otherwise fall back to "Existing
   installs" below.
2. In App Store Connect → Apps → Bai-Tracker note the **Bundle ID** (App
   Information) and the latest **build number** (TestFlight tab).
3. In Xcode, use that bundle ID and team (step 6), and set target → General →
   **Build** to a higher number than the last upload.
4. Run destination **Any iOS Device (arm64)** → **Product → Archive** →
   **Distribute App → TestFlight & App Store → Upload**.
5. When App Store Connect emails that processing is finished (5–15 min),
   TestFlight tab → add the build to the tester group. Answer the export
   compliance question "No" (standard HTTPS only). Testers' phones then offer
   the update in TestFlight.

TestFlight builds **expire 90 days after upload**, so upload at least that
often even without changes.

### Existing installs (only if you cannot access the original team)

If you must start a new app record under a different team / bundle ID, the new
build installs as a **separate app** next to the old one. That is fine: all
projects, points and photos live in AWS, not on the phone. The only local
state is the last-selected project, so users re-pick it on first launch.
Invite testers to the new app in TestFlight and have them delete the old one.

### Google Maps API key

The key is hard-coded in `AppDelegate.swift` (`GMSServices.provideAPIKey`).
In Google Cloud Console → Credentials, that key should be restricted to
**iOS apps** with your new bundle identifier once you have chosen it, and to
the **Maps SDK for iOS** API. If the web app uses the same key, give the web
app its own key restricted by HTTP referrer instead — one key per platform.

### Backend

`amplify_outputs.json` is a copy of the file generated by the web app repo
(`bai-tracking-01/amplify/`). If the backend is ever redeployed or changed,
copy the new file from the web project over this one. Do not edit it by hand.

### Pending fix already in this folder (2026-09-17)

Three files were edited on Windows after the zip was received and should be
included as-is in step 3:

- `ProjectPickerViewController.swift` — `select()` rewritten. Creating a new
  project right after login used to drop the user back on the login screen
  ("Please wait…") because the map was presented via
  `UIWindowScene.windows.first`, which is the keyboard window after typing.
- `LoginViewController.swift`, `RegisterViewController.swift` — clear the
  "Please wait…" state before handing off to the picker/map.

Test after building: sign in → New Project → enter name → Create. Expected:
the map opens full screen on the new project.

## API key setup (required before the first build)

The Google API key is **not** in version control. After cloning, create your
local copy of the secrets file or the build will fail:

```
cp Bai-Tracker/Secrets.swift.example Bai-Tracker/Secrets.swift
```

Then open `Bai-Tracker/Secrets.swift` and replace
`YOUR_GOOGLE_API_KEY_HERE` with a real key.

If you skip this, Xcode fails with **"Build input file cannot be found:
.../Secrets.swift"** — the project references the file, but `.gitignore`
keeps it out of the repo.

The key needs **both** of these enabled in the Google Cloud console:

| API | Used for |
|---|---|
| Maps SDK for iOS | The map view itself |
| Places API (New) | Project-location autocomplete |

If the key is restricted to iOS apps, allow bundle ID `com.bai-eng.tracker`.
Symptoms of a misconfigured key: blank/grey map tiles (Maps SDK missing), or
Google's "this API is not enabled" text appearing in the location search
status line (Places missing).

**Swapping keys later** is a one-line edit to `Secrets.googleAPIKey`. Both
consumers — `AppDelegate` (`GMSServices.provideAPIKey`) and `PlacesService`
(the `X-Goog-Api-Key` header) — read from that single constant. Note the key
is compiled into the binary, so changing it requires shipping a new build.

## Put it in git

A `.gitignore` is already in this folder. It excludes `Bai-Tracker/Secrets.swift`
along with build artifacts and the `__MACOSX/` junk folder left by the zip
export (which you can delete).

```
cd <this folder>
git init
git add .
git commit -m "Recreate Xcode project from exported source"
git remote add origin https://github.com/yfbaiengineers0038/Bai-Tracker-IOS.git
git push -u origin main
```

Before pushing, confirm no credentials are staged:

```
git grep -n "AIza" -- . ; echo "(no output above = clean)"
```
