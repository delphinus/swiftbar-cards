# swiftbar-cards

[日本語](README.ja.md)

[SwiftBar](https://github.com/swiftbar/SwiftBar) plugins that render their dropdowns as image cards instead of rows of text.

| Plugin | Menu bar | Card |
|---|---|---|
| `nowplaying` | Artwork and title of the track playing in Music.app | Artwork, title, artist, album, and playback position, with play/pause and next-track items |
| `sysmon` | CPU history and usage, memory, and temperature | CPU (usage, last 10 minutes, E/P cores, temperatures), memory, top processes by CPU and memory, and Bluetooth device batteries |
| `weather` | Today's weather icon, current temperature, and chance of rain | Current observations, a 24-hour temperature graph, the regional forecast, and the weekly forecast from the Japan Meteorological Agency (JMA) |

Each card is drawn by a small Swift program and passed to SwiftBar as an image, with separate colors for light and dark appearances.

## Requirements

- macOS on Apple Silicon (tested on an M1 Max with macOS 26)
- SwiftBar with support for streamable plugins
- Xcode Command Line Tools (`xcode-select --install`), for `swiftc`
- `jq`, for `weather`

## Installation

```sh
git clone https://github.com/delphinus/swiftbar-cards.git
```

In SwiftBar's settings, set the plugin folder to the `plugins` directory of the clone. The plugins find their Swift sources in the sibling `helpers` directory, so do not copy or link individual plugin files elsewhere.

Each plugin compiles its helper on first run and again whenever the source changes. The binaries are kept under `~/Library/Caches/`.

`nowplaying` asks Music.app for the current track through AppleScript. The first time it runs, macOS asks whether SwiftBar may control Music.

## Configuration

`weather` shows Tokyo by default. The location is currently set by the defaults at the top of `plugins/weather.10m.sh` (`JMA_OFFICE`, `JMA_AREA`, `JMA_CLASS10`, `JMA_TEMP_POINT`, and `JMA_AMEDAS`); the comments there explain where to look up each code. A configuration file that takes a single place name is planned.

## Acknowledgements

`sysmon` reads temperatures from the SMC in the same way as [macmon](https://github.com/vladkens/macmon) (MIT License).

## License

[MIT](LICENSE)
