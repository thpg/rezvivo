# Distribution notes

This source snapshot is published with the project owner's authorization.
It contains no history from the private development workspace. The repository's
existing initial license commit is preserved. No scripts automatically publish
releases or upload to the REZVIVO website.

Included: Windows game source dependencies, portable build and installer scripts,
the installer-selected runtime assets, original workouts, license notices and
the lock file for our CGE fork. Binary assets use Git LFS. DLLs and generated executables
belong in reviewed release packages, not Git source history.

Removed from the source export: developer machine paths, profiles, account/token
stores, real FIT/GPX activities, generated caches, private diagnostic reports,
database/server configuration, previous executables, editor-only resources,
old asphalt textures and third-party workout libraries. Bike JSON files contain
only model metadata and geometry used by the game's parser.

## Remaining release work

The machine-readable list is `dependencies/publication-status.json`.

1. Resolve the remaining asset entries marked REVIEW, notably the BikeInsights
   catalog, some terrain/sky textures, bicycle parts and manhole atlas. BikeInsights
   does not grant an open redistribution license in its [terms](https://bikeinsights.com/terms);
   permission or replacement remains an open redistribution review item. Identical
   Streets GL files already have their MIT attribution; project-generated and
   owner-confirmed Tripo assets are recorded separately.
2. Establish exact source provenance for unversioned runtime DLLs. OpenSSL 1.1.1
   needs an explicit GPL linking permission or replacement with a compatible
   implementation. No additional linking permission has been silently added.
3. Identify/replace SimpleBLE: the current DLL has no version metadata and also
   depends on an absent `simpleble.dll`. Current upstream licensing must not be
   mistaken for the permissive license of an older revision. Windows native BLE
   providers are present in the source.
4. Run the privacy/secret checks immediately before the initial commit and any
   later publication. Automated scans supplement, but cannot replace, review.

Checks do not publish, change a remote or use an account credential. Do not put
private audit logs, model-generation receipts or licenses containing account
details into the repository; keep only distributable notices and provenance.
