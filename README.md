# REZVIVO

<img src="rezvivo-osm-bckl/data/branding/rezvivo.png" alt="REZVIVO logo" width="104">

**Ride real places. Explore imagined worlds. Train your way.**

REZVIVO is an indoor cycling simulator built with Free Pascal and Castle Game
Engine. It combines real-world routes generated from OpenStreetMap and elevation
data with handcrafted Dream Worlds, smart-trainer integration and interval training.

[Website](https://rezvivo.com) · [Download for Windows](https://rezvivo.com/download) ·
[Report an issue on the website](https://rezvivo.com/feedback) or
[GitHub Issues](https://github.com/thpg/rezvivo/issues) · [License](LICENSE)

## Features

- **Real World:** routes with terrain, roads, buildings, water and vegetation
  generated from map data. Import routes or create them on the map.
- **Dream World:** a castle island, a lighthouse island, a forested mountain,
  a futuristic district, a red canyon and an environment showcase.
- **Interval training:** original built-in workouts, power targets, live intensity
  adjustments and a compact workout-only window.
- **Intervals.icu:** a synced training schedule, one-click starts for today's workout,
  and automatic uploads of completed smart-trainer sessions. Simulated sessions
  are excluded from uploads.
- **Devices and simulation:** Bluetooth trainer and sensor integration, plus
  FIT-based simulation for exploring without connected equipment.
- **Bike fitting:** adjustable avatars, riding positions and parametric bicycles.

REZVIVO is in **alpha**. The source build currently targets **Windows x86-64**;
graphics performance and device compatibility are still being refined.
For the ready-to-use application, visit the [download page](https://rezvivo.com/download).

## Screenshots

Click any preview to view the full-size screenshot.

<table>
  <tr>
    <td align="center">
      <a href="https://media.githubusercontent.com/media/thpg/rezvivo/main/docs/screenshots/forest-ride.png"><img src="docs/screenshots/forest-ride.png" alt="A forest road ride with live cycling metrics" height="220"></a><br>
      Forest ride
    </td>
    <td align="center">
      <a href="https://media.githubusercontent.com/media/thpg/rezvivo/main/docs/screenshots/city-ride.png"><img src="docs/screenshots/city-ride.png" alt="Riding through a city with live cycling metrics" height="220"></a><br>
      City ride
    </td>
  </tr>
  <tr>
    <td align="center">
      <a href="https://media.githubusercontent.com/media/thpg/rezvivo/main/docs/screenshots/workout-library.png"><img src="docs/screenshots/workout-library.png" alt="The interval workout library with workout profiles" height="220"></a><br>
      Workout library
    </td>
    <td align="center">
      <a href="https://media.githubusercontent.com/media/thpg/rezvivo/main/docs/screenshots/workout-only.png"><img src="docs/screenshots/workout-only.png" alt="The compact workout-only window with interval controls" height="220"></a><br>
      Compact workout mode
    </td>
  </tr>
</table>

## Build from source

Requirements: **Free Pascal 3.2.2 for Windows x86-64** (including `windres.exe`
and `cpp.exe`), PowerShell 5.1 or later, and Git with [Git LFS](https://git-lfs.com/).
A suitable FPC installation is included with Lazarus.

After the one-time source and engine setup below, compile the Pascal application
from the repository root:

```powershell
powershell -File rezvivo-osm-bckl/build-performance-release.ps1 `
  -EngineRoot "$PWD/../rezvivo-dependencies/cge" `
  -Compiler "C:/tools/fpc/3.2.2/bin/x86_64-win64/fpc.exe"
```

Replace the compiler path with your installation. The script invokes `fpc.exe`
to compile the game and CGE, and `windres.exe` to embed the version and icon.

<details>
<summary>First-time source and CGE setup</summary>

Run these commands once in PowerShell. Use a new directory for CGE:

```powershell
git lfs install
git clone https://github.com/thpg/rezvivo.git
cd rezvivo
git lfs pull

$engine = "$PWD/../rezvivo-dependencies/cge"
$lock = Get-Content dependencies/engine.json -Raw | ConvertFrom-Json
git init $engine
git -C $engine config core.autocrlf false
git -C $engine remote add origin $lock.repository
git -C $engine sparse-checkout init --cone
git -C $engine sparse-checkout set src doc/licenses
git -C $engine fetch --depth=1 --filter=blob:none origin $lock.commit
git -C $engine checkout --detach FETCH_HEAD
git -C $engine apply --check "$PWD/patches/cge-rezvivo.patch"
git -C $engine apply "$PWD/patches/cge-rezvivo.patch"
```

This checks out the pinned engine revision from [the dependency lock](dependencies/engine.json)
and applies [our CGE patch](patches/cge-rezvivo.patch). The engine stays in the sibling
`rezvivo-dependencies/cge` directory, outside this repository.

</details>

The executable is written to `rezvivo-osm-bckl/third_person_navigation.exe`.
Keep `data` beside it. Runtime DLLs are supplied separately;
[dependencies/runtime.json](dependencies/runtime.json) lists the expected files,
observed versions, hashes and upstream sources. Compilation does not require
those DLLs, but running and packaging the client does.

Review the [distribution notes](PUBLICATION.md) before redistributing a binary package.

## Repository layout

| Directory | Contents |
| --- | --- |
| `rezvivo-osm-bckl/code` | Game, menus, rides, workouts, devices and client services |
| `rezvivo-osm-bckl/data` | Runtime assets selected by the installer |
| `Bikeparametric` | Shared bicycle, rider, pose and animation code |
| `Osm3d` | World generation, rendering, terrain, roads, vegetation and tile caching |
| `tree-editor/core`, `tree-editor/render` | Vegetation modules used by the game |
| `Mcp` | Diagnostic interface modules |
| `patches`, `dependencies` | CGE changes, dependency versions and asset provenance |
| `tools`, `.github` | Source checks and continuous integration |

This repository contains the game and the shared modules needed to build it.
Standalone editor applications and server deployment code are separate.
The seven included workouts are original REZVIVO workouts.

## Contributing

Report bugs and suggest improvements through the
[website feedback form](https://rezvivo.com/feedback) or
[GitHub Issues](https://github.com/thpg/rezvivo/issues).
For rendering issues, include the game version, GPU, graphics settings and the
route or Dream World involved. Review attached logs for personal information.

Automated publication checks validate the file allowlist and runtime asset hashes,
inspect model metadata and run Gitleaks. Update `dependencies/files.json` when adding
reviewed source files and `dependencies/assets.json` when changing packaged assets.
CI also checks Git history for secrets. No automatic deployment jobs are included.

## License and third-party content

REZVIVO-owned source code and original assets are licensed under
**GPL-3.0-or-later**: GNU General Public License version 3, or, at your option,
any later version. See [LICENSE](LICENSE).

Third-party components retain their own licenses and attribution.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
[the asset inventory](dependencies/assets.json) and
[the open provenance and binary-distribution review](PUBLICATION.md).
An entry marked `REVIEW` is not a declaration that its rights have been cleared.
Downloaded OpenStreetMap data remains subject to its own attribution and license.
