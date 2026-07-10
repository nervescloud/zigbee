# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-10

### Added

- `Zigbee.ZCL.write_attributes/3` — manufacturer-specific writes (optional
  `:manufacturer_code`) plus octet-string (`0x41`) value encoding.
- `Zigbee.EZSP.Adapter`: injectable EZSP process via the `:ezsp` option, with
  integration tests driven by a fake NCP (`Zigbee.FakeEZSP`).
- Trust-center / end-device config suite applied on both form and reestablish
  (TC address cache, indirect-transmission / end-device-poll / transient-key
  timeouts, max end-device children).
- Well-known transient link key installed on `permit_joining/2`, hashed
  trust-center link keys, and an Aqara/Lumi manufacturer-code join workaround.

### Fixed

- EZSP key-request policy ids were wrong (`TC_KEY_REQUEST` `0x09`→`0x05`,
  `APP_KEY_REQUEST` `0x0A`→`0x06`) and the TC-key decision was inverted (`0x50`
  is DENY; now `0x51` = allow). Zigbee 3.0 devices that request keys now
  commission instead of rejoin-looping.
- `incomingMessageHandler` decode crashed on EmberZNet v13 frames that append a
  trailing byte after the APS payload.
- Trust-center / key-request policies are now re-applied on
  `reestablish_network/2` — they are volatile across NCP reboots.
- Security bitmask corrected: removed the stray `GET_LINK_KEY_WHEN_JOINING`
  flag (wrong on a coordinator) and switched to hashed link keys.

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
