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
- **Devices and simulation:** Bluetooth trainer and sensor integration, plus
  FIT-based simulation for exploring without connected equipment.
- **Bike fitting:** adjustable avatars, riding positions and parametric bicycles.

REZVIVO is in **alpha**. The source build currently targets **Windows x86-64**;
graphics performance and device compatibility are still being refined.
For the ready-to-use application, visit the [download page](https://rezvivo.com/download).

## Build from source

Requirements: Git with [Git LFS](https://git-lfs.com/), Python 3.9 or later,
PowerShell 5.1 or later, and Free Pascal 3.2.2 for Windows x86-64, including
`windres.exe` and `cpp.exe`. A suitable FPC installation is included with Lazarus.

```powershell
git lfs install
git clone https://github.com/thpg/rezvivo.git
cd rezvivo
git lfs pull

python tools/fetch-engine.py
pwsh -File rezvivo-osm-bckl/build-performance-release.ps1 `
  -EngineRoot "$PWD/../rezvivo-dependencies/cge" `
  -Compiler "C:/tools/fpc/3.2.2/bin/x86_64-win64/fpc.exe"
```

Replace the compiler path with your installation. Use `powershell` instead of
`pwsh` for Windows PowerShell 5.1. Git LFS is required for the binary assets.

The engine helper downloads a pinned CGE revision and applies
[our engine patch](patches/cge-rezvivo.patch), checking hashes against
[the dependency lock](dependencies/engine.json). CGE lives in the sibling
`rezvivo-dependencies/cge` directory, outside this repository. Use `--destination`
to choose another location or `--verify-only` to check an existing checkout.
The full CGE repository is not vendored here.

The executable is written to `rezvivo-osm-bckl/third_person_navigation.exe`.
Keep `data` beside it. Runtime DLLs are supplied separately;
[dependencies/runtime.json](dependencies/runtime.json) lists the expected files,
observed versions, hashes and upstream sources. Compilation does not require
those DLLs, but running and packaging the client does.

## Create an installer

After supplying the runtime libraries, prepare a local payload:

```powershell
python rezvivo-osm-bckl/tools/build-installer.py `
  --stage-only --out dist --runtime-dir C:/tools/rezvivo-runtime
```

To build the single-file Windows setup, replace `--stage-only` with
`--nsis C:/tools/NSIS/makensis.exe`. NSIS is required only for this step.
The scripts also support manifest-based updates. Review the
[distribution notes](PUBLICATION.md) before redistributing a binary package.

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

Before contributing files, run the local privacy and secret checks:

```powershell
python tools/check-publication.py --gitleaks C:/tools/gitleaks.exe
```

The checks validate the file allowlist and runtime asset hashes, inspect model
metadata and run Gitleaks locally. Update `dependencies/files.json` when adding
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
