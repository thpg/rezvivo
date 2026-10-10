# REZVIVO

<img src="rezvivo-osm-bckl/data/branding/rezvivo.png" alt="REZVIVO logo" width="104">

**Train, or simply explore the world in 3D.**

REZVIVO is an open-source app for indoor cycling and exploring OpenStreetMap in
3D. Train on your smart trainer, or choose a place on the map and walk, cycle or
fly using your keyboard. You can explore without a trainer or a prepared route.

Terrain, roads, buildings, water and vegetation are generated from OSM and
elevation data, with map tiles loaded as you move. Handcrafted Dream Worlds and
interval workouts offer more ways to ride.

[Website](https://rezvivo.com) · [Download for Windows](https://rezvivo.com/download) ·
[Report an issue on the website](https://rezvivo.com/feedback) or
[GitHub Issues](https://github.com/thpg/rezvivo/issues) · [License](LICENSE)

## Features

- **Free exploration:** start from a point on the map, walk or run, cycle with
  keyboard power controls, or use free flight to look around.
- **3D OSM streaming:** terrain, roads, buildings, water and vegetation generated
  from map and elevation data. Nearby areas load as you move. Import routes or
  create them on the map when you want to follow a planned ride.
- **Dream World:** a castle island, a lighthouse island, a forested mountain,
  a futuristic district, a red canyon and an environment showcase.
- **Interval training:** original built-in workouts, power targets, live intensity
  adjustments and a compact workout-only window.
- **Intervals.icu:** a synced training schedule, one-click starts for today's workout,
  and automatic uploads of completed smart-trainer sessions. Simulated sessions
  are excluded from uploads.
- **Devices and simulation:** Bluetooth trainer and sensor integration, plus
  FIT-based simulation for exploring without connected equipment. Elite STERZO
  Smart supports steering in free exploration and lane changes on routes,
  including while FIT simulation supplies power and cadence.
- **Bike fitting:** adjustable avatars, riding positions and parametric bicycles,
  with automatic frame sizing and saddle, stem and spacer adjustment.

Built with Free Pascal and Castle Game Engine, REZVIVO is in **alpha**.
The source build currently targets **Windows x86-64**;
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
git -C $engine sparse-checkout set src doc/licenses tools packages
git -C $engine fetch --depth=1 --filter=blob:none origin $lock.commit
git -C $engine checkout --detach FETCH_HEAD
```

This checks out the pinned revision of the [`rezvivo` branch in our CGE fork](https://github.com/thpg/castle-engine/tree/rezvivo),
as recorded in [the dependency lock](dependencies/engine.json). Our engine changes
are already committed; there is no separate patch to apply. The engine stays in the sibling
`rezvivo-dependencies/cge` directory, outside this repository.

</details>

To edit `.castle-user-interface` designs, use Lazarus and the CGE editor from
this pinned engine. Open `rezvivo-osm-bckl/CastleEngineManifest.xml` and choose
**Project → Restart Editor (With Custom Components)**. The manifest declares
`GameMenuTheme`, `GameEnemy` and `Osm3dImpostorCache` as `editor_units`, including
the `TMenuButton` and `TOsmImpostorViewport` classes used by the UI designs.
Configure the Lazarus path in the editor's
preferences if it cannot find `lazbuild`.

The executable is written to `rezvivo-osm-bckl/third_person_navigation.exe`.
Keep `data` beside it. Runtime DLLs are supplied separately;
[dependencies/runtime.json](dependencies/runtime.json) lists the expected files,
observed versions, hashes and upstream sources. Compilation does not require
those DLLs, but running and packaging the client does.

The optional RTX backend has its source in [Osm3d/rtx](Osm3d/rtx). To build it,
install the Visual C++ x64 build tools and a Vulkan SDK shader compiler, then add
`-BuildRtx -Glslang "C:/VulkanSDK/<version>/Bin/glslangValidator.exe"` to the build
command above. Its script fetches the pinned Khronos headers and copies the DLL
and compiled shaders beside the game. The regular Pascal build uses raster
rendering when the RTX backend is unavailable.

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
| `dependencies` | Pinned CGE fork, dependency versions and asset provenance |
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
