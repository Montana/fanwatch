# FanWatch

A lightweight native macOS app for watching your Mac's fans and temperatures in real time — with live charts, a configurable menu bar readout, and full sensor auto-discovery. Works on Apple Silicon and Intel Macs. No kernel extensions, no root, no third-party dependencies.

## Build & run

```bash
cd FanWatch
./build.sh
open FanWatch.app
```

Requirements: macOS 13 Ventura or newer, and the Xcode command line tools (`xcode-select --install` if you don't have them). To keep it around, drag `FanWatch.app` into /Applications.

You can also open the folder directly in Xcode (`File → Open… → Package.swift`) and hit Run.

## How it's flexible

- **Auto-discovery** — on launch it scans every key the System Management Controller exposes and lists everything that looks like a fan or a plausible temperature sensor. You're not limited to a hardcoded list; whatever your specific Mac model reports, you'll see.
- **Pick your sensors** — checkboxes in the sidebar control what gets charted. A search field filters the list.
- **Menu bar readout** — choose any single sensor to live in your menu bar (CPU temp, a fan's RPM, whatever). Clicking it shows a mini dashboard of all selected sensors.
- **Tunable polling** — refresh interval from 0.5s to 10s, chart history from 1 to 60 minutes, °C/°F toggle. All settings persist across launches.

## Notes

- Fans are read from the SMC `F#Ac` keys (actual RPM). Fanless Macs (MacBook Air M-series) will simply show no fan section — the temperature side still works fully.
- Common sensors get friendly names ("CPU Proximity", "Fan 1"); unrecognized ones show their raw 4-character SMC key. Apple doesn't document these, so if you want to label one yourself, add it to the dictionary in `Sources/FanWatch/SensorStore.swift` (`SensorNames.known`).
- Reading the SMC works from a normal unprivileged app; *controlling* fan speed would require elevated privileges and is deliberately out of scope here.
- It won't work inside a VM — the SMC isn't exposed there.

## Project layout

```
Package.swift                     Swift Package definition
Sources/FanWatch/
  FanWatchApp.swift               App entry + menu bar extra
  ContentView.swift               Sidebar, charts (Swift Charts), settings
  SensorStore.swift               Polling loop, history, discovery, prefs
  SMC.swift                       Low-level AppleSMC client (IOKit)
build.sh                          Builds and packages FanWatch.app
```
