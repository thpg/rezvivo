# Third-party notices

The root GPL license covers REZVIVO contributions. It does not relicense foreign
libraries, datasets or assets. Existing notices inside source files remain intact.

| Component | License / source | Handling |
| --- | --- | --- |
| Castle Game Engine | [LGPL 2.0 or later with static-linking exception](https://castle-engine.io/license) | Fetch the pinned commit from [our CGE fork](https://github.com/thpg/castle-engine/tree/rezvivo). Changes are committed on the `rezvivo` branch. Preserve upstream notices, including licenses of bundled subcomponents. |
| Free Pascal runtime | [Modified LGPL / linking exception](https://www.freepascal.org/faq.html#general-license) | Install compiler separately. |
| Streets GL textures and adapted rendering algorithms | [MIT, copyright 2020–2023 StrandedKitty](https://github.com/StrandedKitty/streets-gl/blob/dev/LICENSE) | Full notice in LICENSES/Streets-GL-MIT.txt. Exact texture matches are identified in dependencies/assets.json. |
| Audio ambiences | CC0; original sources and authors in data/audio/credits.json | Original REZVIVO cues use the project license. |
| Menu fonts | Their adjacent font license files | Keep those notices with redistributed fonts. |
| MakeHuman head assets | CC0-1.0 asset data; no application code | The adapted head is part of the shared rider. Preserve data/licenses/makehuman/NOTICE.txt. |
| Original Tripo models | Project-owned output, as confirmed by the owner | REZVIVO license; Tripo is a generation service, not a runtime library. |
| Lighthouse credit | CC BY 4.0 notice already supplied in data/license.txt | Preserve the credit; it does not license every model in the project. |
| Bike geometry catalog | Numerical geometry projected from BikeInsights responses | Website configuration and unrelated records removed. The [site terms](https://bikeinsights.com/terms) do not provide an open redistribution license; obtain permission or replace the catalog before publication. |
| Other packaged textures/models | Per-file provenance in dependencies/assets.json | Unknowns are marked REVIEW rather than assigned an invented license. |

The runtime libraries are not vendored. Their upstream source links and exact
observed binary hashes are in dependencies/runtime.json. In particular, the
current OpenSSL 1.1.1 binaries need a GPL compatibility decision; the unversioned
SimpleBLE wrapper needs source/license identification or replacement. GPL source
publication and redistribution of the existing installer are separate decisions.

Map data downloaded during use is not part of this repository. OpenStreetMap
data remains subject to [ODbL and attribution](https://www.openstreetmap.org/copyright).
Elevation, map services and user-imported data retain their providers' terms.

Tripo's [terms](https://www.tripo3d.ai/terms) distinguish paid and free generation
rights. The owner confirmed the rider and helmet models as project-created;
retain generation/ownership evidence privately, not API keys or account exports.
