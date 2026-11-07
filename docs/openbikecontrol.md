# OpenBikeControl controllers

REZVIVO supports the OpenBikeControl BLE input service for virtual shifting and
steering. This is an optional input path alongside direct Zwift controllers,
STERZO, gamepads and keyboard controls. No bridge application, cloud account or
new runtime library is required by REZVIVO. Some controllers need an external
bridge that advertises OpenBikeControl; that bridge is a separate product.

## Pairing and use

1. Enable Bluetooth and wake the controller or start its BLE bridge.
2. In **Connect devices**, select the advertised device explicitly. Its display
   name can be anything: REZVIVO identifies the service by its advertised UUID.
3. Use the shifting role for virtual gears, and select its steering sensor if
   wanted. An existing STERZO can remain the steering source.

The saved selection reconnects automatically. Nearby unselected OpenBikeControl
controllers are not connected automatically. Disabling the shifting role or
virtual shifting is respected; enabling it again does not replay old presses.
Controllers also work during FIT playback, without replacing simulated power,
cadence, heart rate or trainer control. ERG behavior and measured activity data
remain unchanged.

## Implemented protocol

- BLE service `d273f680-d548-419d-b9d1-fa0472345229`.
- Shift Up/Down (`01`, `02`), Steer Left/Right (`18`, `19`) and calibrated steering
  angle (`1B`). The angle takes precedence over steering buttons while available.
- Changed-button notifications retain held state. Shift presses use the existing
  journal so multiple presses within one rendered frame are preserved.
- Optional App Information identifies `rezvivo`, its version and exactly these
  five supported actions. Unsupported or rejected optional information writes
  do not reject an otherwise usable controller. A stalled GATT queue still
  reports a connection error so it can be reconnected safely.
- Notifications received during discovery are retained and delivered after
  connection completes. Reconnection clears old held state and uses a new shared
  controller generation.
- A peripheral exposing native Zwift or STERZO services keeps the native path;
  its OBC input is ignored to prevent two journals driving one controller.
  Native trainer handshakes and virtual-gearing commands retain priority too.

This integration does not implement OBC TCP/mDNS, haptics, other button actions
or same-device communication with a bridge through local IPC. It does not imply
direct support for every device understood by an external bridge.

## Specification and verification

Implemented against the [MIT protocol specification at revision
3ac4146](https://github.com/OpenBikeControl/openbikecontrol-protocol/tree/3ac4146956cb011a95787b1e784adbab4b7a9e83).
The protocol notice is retained in `LICENSES/OpenBikeControl-Protocol-MIT.txt`.
No BikeControl application implementation is copied, linked or bundled.

`OpenBikeControlTests.pas` checks parsing, malformed input, held buttons, combined
actions, angle precedence, initial snapshots and protocol journal generations.
`OpenBikeControlServiceTests.pas` exercises explicit pairing, remembered devices,
FIT isolation, early input, coalesced presses, opt-out and reconnection using a
mock BLE provider with the production device manager and service. Run the latter
with an isolated test profile, both without arguments and with `simulation`.
Existing steering, controller, telemetry and virtual-gearing suites cover the
native paths. These automated checks do not replace testing physical controllers
and bridges on each operating system.

`AndroidBleQueueTest.py --jdk /path/to/jdk` runs the actual Android completion
and rejection methods with substituted scheduling/connection side effects. It
checks that rejected App Information writes continue the queue, while failed
subscriptions and trainer commands retain normal error handling.
