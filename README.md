# OneTurn for iPhone

A small iPhone app that opens [OneTurn](https://alpineops.eu/apps/oneturn/), the EV navigation web app for the Nissan Leaf e+, full screen.
The app itself is only a frame. Everything you see comes from alpineops.eu, so updates to the web app appear in the app on the next start, without a new install.

What the frame adds:
- location from the phone's GPS, with the permission asked once (Settings > OneTurn > Location);
- the screen stays on while driving;
- Export in Settings opens the share sheet (Save to Files, AirDrop, Mail);
- links to other websites open in Safari;
- the last loaded version keeps working without mobile data (offline copy).

## Download

Latest build: https://github.com/dsapoki/oneturn/releases/latest/download/OneTurn.ipa

The file is **unsigned** on purpose: AltStore signs it with your own Apple ID when it installs it.

## Install with AltStore

1. Install AltStore Classic on the iPhone (see altstore.io).
2. On the iPhone, open the download link above in Safari and save the file.
3. In Files, open the file's share menu and pick AltStore (or in AltStore: My Apps > +).
4. On iOS 16 or later, turn on Settings > Privacy & Security > Developer Mode if asked.

With a free Apple ID the app must be refreshed in AltStore at least every 7 days.

## Your data

The app keeps its own copy of settings, learned consumption, prices and favourites, separate from Safari.
To move them: in Safari's OneTurn, Settings > Export; in the app, Settings > Import.

## Build

Every push to `main` builds `OneTurn.ipa` on GitHub (Actions) and publishes it as the latest release.
The Xcode project is generated from `project.yml` with XcodeGen.
