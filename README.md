# Title Update Manager

An [Aurora](https://consolemods.org/wiki/Xbox_360:Aurora) Lua utility script for Xbox 360 that merges two previously separate community scripts into one:

- **Title Update Downloader** — browse your installed games and download their Title Updates straight from [XboxUnity](http://xboxunity.net/), or update every game at once to its latest Title Update.
- **Title Update Enabler** — enable/disable the Title Updates Aurora already knows about, or permanently apply the currently-enabled ones out of Aurora's managed cache.

It exists as a temporary workaround for Aurora 0.7b2 and earlier, whose native Title Update hash check is broken.

## Features

- **Browse a single game** — pick a game, see its available Title Updates (with a checkmark on ones you already have installed), download, verify (MD5), and register the one you want.
- **Update ALL Games (Latest Only)** — scans every installed game, finds the newest Title Update for each on XboxUnity, and downloads/installs whichever ones you're missing, in one confirmed batch (single drive prompt, single summary, no per-game pop-ups).
- **Manage Cached Title Updates**:
  - *Enable Latest Updates* — marks the highest-version Title Update per game as active.
  - *Disable Latest Updates* — deactivates all currently-enabled Title Updates.
  - *Mass Apply Latest Updates* — permanently moves the active Title Updates out of Aurora's backup cache into their live location and removes them from Aurora's database. **This is irreversible** — only use it if you don't intend to keep managing Title Updates through Aurora.

## Requirements

- Aurora dashboard (0.7b2 or earlier — this is a workaround for a hash-check bug fixed in later versions).
- An active internet connection (the script refuses to run without one).

## Installation

1. Copy the `TitleUpdateManager` folder to `Aurora\User\Scripts\Utility\` on your console (or the equivalent path for your Aurora content drive).
2. Launch it from Aurora's Utility Scripts menu.

## Usage

- Select a game from the list to browse and install a specific Title Update, exactly like the original downloader.
- Select **`-- Update ALL Games (Latest Only) --`** to update every installed game to its newest Title Update in one pass.
- Select **`-- Manage Cached Title Updates --`** to enable, disable, or permanently apply the Title Updates already registered in Aurora's database.

After installing or applying updates, restart Aurora when prompted so the changes take effect, then enable the update from each game's own Title Updates menu if you used the download/update-all flow.

## Credits

- **Swizzy & EccentricVamp** — original *Title Update Downloader*.
- **FDH** — original *Title Update Enabler*.
- **Yirr777** — merged both scripts into one, added the "Update ALL Games" batch flow, and redesigned the icon.

## License

Released into the public domain under [the Unlicense](LICENSE).
