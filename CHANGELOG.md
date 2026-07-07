# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-07

Initial release: a from-scratch, pure-Elixir Zigbee coordinator stack for Silicon
Labs EmberZNet dongles. No NIFs and no C daemons, just `circuits_uart` and binary
pattern matching.

### Added

- `Zigbee` facade: the backend-agnostic public API (`start_link/2`, `form_network/2`,
  `reestablish_network/2`, `reestablish_or_form_network/2`, `reset_network/1`,
  `permit_joining/2`, `add_endpoint/6`, `send_aps/7`, `identifier/1`, `subscribe/2`,
  `info/1`).
- `Zigbee.Adapter`: the behaviour that separates the application layer from the
  radio. Backends emit normalized `{:zigbee, :device_joined, _}` and
  `{:zigbee, :message, %Zigbee.Message{}}` events.
- `Zigbee.EZSP.Adapter`: the Silicon Labs EmberZNet backend (EZSP over ASH),
  including the ASH framing, the EZSP protocol client, and NCP diagnostics. Verified
  live against a Home Assistant Connect ZBT-2 on EmberZNet 7.5.1.0.
- `Zigbee.ZCL` and `Zigbee.ZDO`: chip-agnostic Zigbee-spec codecs for cluster-library
  and device-object frames.
- `Zigbee.Interview`: the join, interview, bind, and configure-reporting flow, plus
  `collect/2` to decode incoming reports into engineering units.
- `Zigbee.Message`: the normalized inbound APS message.
- `Zigbee.MockAdapter`: an in-memory backend for testing without hardware.
- Examples: `pair_and_read.exs` (a runnable end-to-end demo) and `sensor_hub.exs`
  (a supervised GenServer that owns the radio and reacts to events).

### Known limitations

- The pairing flow (`Interview.run/4` and report decoding) is written to the spec
  and tested against `Zigbee.MockAdapter`, but has not yet been exercised against
  live Zigbee end-devices. Expect to tune the incoming-message layout and
  per-device quirks.
- `reestablish_network/2` is implemented but not yet confirmed against real paired
  devices across a restart. See "Persistence & restart" in the README.
- Only the Silicon Labs EmberZNet (EZSP) family is supported. TI Z-Stack and deCONZ
  radios need their own `Zigbee.Adapter` backend.

[0.1.0]: https://github.com/nervescloud/zigbee/releases/tag/v0.1.0
