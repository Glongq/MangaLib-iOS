# Class Pulse Test

An independent SwiftUI proof of concept for a lesson countdown Live Activity. It uses local ActivityKit updates, so it needs no server, push notifications, or paid account capability.

## Run on an iPhone

1. Open `ClassPulseTest.xcodeproj` in Xcode.
2. Select your Apple Personal Team for both the app and widget extension. Change the bundle identifier prefix if it is already taken.
3. Run the `ClassPulseTest` scheme on an iPhone with iOS 17 or newer.
4. Allow Live Activities in Settings, then tap **Start 10-minute test**.
5. Lock the phone or check Dynamic Island. Tap **End test** to dismiss it.

LiveContainer cannot register a guest app's widget extension with iOS, so this test must be installed as a separate app. The compact display uses a numeric `mm:ss` countdown inside a circle. It updates through the system timer without repeated app or push updates.

The lesson names and duration are sample data. Timetable editing and automatic lesson transitions are outside this feasibility test.

If you change `project.yml`, regenerate the project with `xcodegen generate --spec project.yml` from this folder.

## Package an IPA

Install full Xcode with the iOS platform support. To create an unsigned IPA, run:

```sh
./build-ipa.sh
```

The IPA is written to `dist/ClassPulseTest.ipa`. An unsigned IPA can be inspected or signed later, but cannot be installed directly on an iPhone. To build a development-signed IPA instead, sign in to Xcode and run `APPLE_TEAM_ID=YOUR_TEAM_ID ./build-ipa.sh`. The Apple Team must be able to provision both the app and its widget extension.
