# zigbee

A from-scratch, pure-Elixir Zigbee stack. No NIFs, no C daemons, just
`circuits_uart` and binary pattern matching. It runs a Zigbee coordinator on a
Silicon Labs EmberZNet dongle: form a network, pair devices, and read their
clusters (temperature, humidity, switches, …).

```elixir
{:zigbee, "~> 0.1.0"}
```

## Quick start

The following example shows the flow to open the dongle (eg. ZBT-2), form a network, 
pair a sensor, and read data from it:

```elixir
# 1. open the radio and become its event subscriber
{:ok, zb} = Zigbee.start_link(Zigbee.EZSP.Adapter, device: "/dev/ttyACM0", speed: 460_800)
:ok = Zigbee.subscribe(zb, self())

# 2. form a coordinator network (also registers a default Home Automation endpoint)
{:ok, params} = Zigbee.form_network(zb, channel: 15)
#=> {:ok, %{channel: 15, pan_id: 0x63ED, ...}}

# 3. open joining, then put the device (eg. temp sensor) into pairing mode (usually by pressing a 'pair' button)
{:ok, dev} = Zigbee.Interview.open_and_wait(zb)
#=> {:ok, %{node_id: 0xA1B2, eui64: <<...>>}}

# 4. interview it: enumerate endpoints, bind + configure reporting for temp/humidity
{:ok, _summary} = Zigbee.Interview.run(zb, dev.node_id, dev.eui64)

# 5. watch the readings arrive (°C / %)
Zigbee.Interview.collect(zb, 60_000)
#=> [%{cluster: 0x0402, endpoint: 1, value: 21.4, unit: "°C"},
#    %{cluster: 0x0405, endpoint: 1, value: 47.8, unit: "%"}]
```

## Usage

### Opening a radio

`Zigbee.start_link/2` takes a backend module (implementing `Zigbee.Adapter`) and
its options, and returns a handle used by every other call:

```elixir
{:ok, zb} = Zigbee.start_link(Zigbee.EZSP.Adapter, device: "/dev/ttyACM0", speed: 460_800)
Zigbee.info(zb)   #=> %{protocol_version: 13, stack_version: "7.5.1.0", stack_type: 2}
```

For the EmberZNet backend, `:device` is the serial port and `:speed` the baud rate
(460_800 for the ZBT-2; many other sticks default to 115_200).

### Forming a network

`Zigbee.form_network/2` runs the full centralized (trust-center) coordinator setup and
returns once the network is up. Endpoints are registered as part of forming
(they must exist before the network comes up), so a plain `form_network/1` is enough:

```elixir
{:ok, params} = Zigbee.form_network(zb, channel: 15)
```

Options: `:channel` (11..26, default 15), `:pan_id`, `:extended_pan_id`,
`:tx_power`, `:network_key`, `:tc_link_key` (trust-center link-key master; random
by default), and `:endpoints` (`:default`, `:none`, or a list of
`{endpoint, profile, device_id, in_clusters, out_clusters}`).

### Pairing a device

`Zigbee.Interview` orchestrates the whole join → interview → bind → report flow.
The process that calls it must be the adapter's subscriber (`Zigbee.subscribe/2`).

```elixir
# opens the join window and blocks until a device joins (default 180s)
{:ok, dev} = Zigbee.Interview.open_and_wait(zb)

# enumerate the device's endpoints/clusters, then bind + configure reporting
# on every temperature (0x0402) and humidity (0x0405) cluster it exposes
{:ok, summary} = Zigbee.Interview.run(zb, dev.node_id, dev.eui64)
#=> {:ok, %{endpoints: [1], descriptors: [...], bindings: [...]}}
```

`run/4` takes `:min_interval` / `:max_interval` (reporting bounds in seconds).

### Reading reports

After `run/4` has configured reporting, the device pushes updates on its own. Use
`collect/2` to gather and decode them into engineering units:

```elixir
Zigbee.Interview.collect(zb, 60_000)
#=> [%{cluster: 0x0402, endpoint: 1, value: 21.4, unit: "°C"}, ...]
```

### Sending your own commands

For anything the `Interview` helpers don't cover, build a raw APS payload with the
spec codecs and send it with `Zigbee.send_aps/7`:

```elixir
# read the Basic cluster's manufacturer + model (attrs 0x0004, 0x0005) on endpoint 1
frame = Zigbee.ZCL.read_attributes(_seq = 1, [0x0004, 0x0005])
{:ok, _aps_seq} = Zigbee.send_aps(zb, dev.node_id, 0x0104, 0x0000, 1, frame)
# the reply arrives as {:zigbee, :message, %Zigbee.Message{}}; decode it with Zigbee.ZCL.decode/1
```

Writes work the same way. `Zigbee.ZCL.write_attributes/3` takes a
`:manufacturer_code` for vendor-specific attributes:

```elixir
# write an Aqara manuSpecificLumi attribute (cluster 0xFCC0, attr 0x0009 = 1)
frame = Zigbee.ZCL.write_attributes(1, [%{attr_id: 0x0009, type: 0x20, value: 1}],
          manufacturer_code: 0x115F)
{:ok, _aps_seq} = Zigbee.send_aps(zb, dev.node_id, 0x0104, 0xFCC0, 1, frame)
```

### Handling events yourself

The subscriber receives backend-neutral events. `Zigbee.Interview` consumes these
for you, but you can handle them directly for custom flows:

```elixir
receive do
  {:zigbee, :device_joined, %{node_id: id, eui64: eui}} -> ...
  {:zigbee, :message, %Zigbee.Message{cluster: c, payload: p}} -> Zigbee.ZCL.decode(p)
end
```

## Examples

[`examples/pair_and_read.exs`](examples/pair_and_read.exs) is a complete, runnable
demo: form a network, pair one device, and print its readings live.

```sh
# defaults to /dev/ttyACM0 @ 460800 baud, channel 15
mix run examples/pair_and_read.exs

# override via env vars (e.g. a ZBT-2 on macOS)
ZBT_DEVICE=/dev/cu.usbmodem1CDBD45F0F5C1 ZBT_CHANNEL=20 mix run examples/pair_and_read.exs
```

[`examples/sensor_hub.exs`](examples/sensor_hub.exs) shows how to run this from a
supervised GenServer that owns the radio, subscribes to events, and reacts to joins
and reports in `handle_info/2`. It also shows the one gotcha: handle the event stream
reactively rather than calling the blocking `Zigbee.Interview.*` helpers from inside
a process.

```elixir
children = [{SensorHub, device: "/dev/ttyACM0", speed: 460_800, channel: 15}]
Supervisor.start_link(children, strategy: :one_for_one)

SensorHub.open_joining(120)   # then put a device into pairing mode
SensorHub.readings()          #=> %{0xA1B2 => %{0x0402 => %{value: 21.4, unit: "°C", ...}}}
```

## Persistence & restart

Almost none of the important state lives in your Elixir process. It lives in the
dongle's flash (NVM3) and on the devices themselves:

| State | Lives in | Survives app restart | Survives dongle reboot |
| --- | --- | --- | --- |
| Network: PAN, channel, network key, TC link key | Dongle NVM3 | ✅ | ✅ |
| Joined devices + EUI64↔node-id table | Dongle NVM3 | ✅ | ✅ |
| APS link keys | Dongle NVM3 | ✅ | ✅ |
| Endpoints (`add_endpoint`) | Host RAM (NCP doesn't persist them) | ⚠️ re-register each boot | ⚠️ re-register each boot |
| TC / key-request policies + NCP config | Host RAM (volatile) | ⚠️ re-applied on reestablish | ⚠️ re-applied on reestablish |
| Bindings + reporting config | On the device (its own flash) | ✅ | ✅ |
| Your app state (`readings`, device list) | Your process | ❌ rebuild it | ❌ rebuild it |

The consequence: after a crash or restart, do not call `form_network/2` again.
Forming makes a new network (new key) and orphans every paired device. Instead,
re-establish the stored network:

```elixir
# on start-up: rejoin the existing network, or form one only on first run
case Zigbee.reestablish_network(zb) do
  {:ok, params}          -> :reestablished  # existing devices reconnect on their own
  {:error, :no_network}  -> Zigbee.form_network(zb)  # first run: form a fresh network
end

# or the convenience wrapper:
Zigbee.reestablish_or_form_network(zb, channel: 15)
```

`reestablish_network/2` re-applies the host-side state the NCP drops on reset —
the endpoints **and** the trust-center / key-request policies and config — then
calls `networkInit`. Because bindings and reporting live on the devices, they keep
reporting to the coordinator with no re-pairing or re-interviewing, as long as
it comes back on the same network with the same endpoints. Your app-level state
(the readings map) is the only thing you rebuild; it repopulates as reports arrive
(the `SensorHub` example tracks devices as it hears from them, and a fuller hub can
read the NCP's child/address table to repopulate the list eagerly).

The stored network survives NCP resets in practice: forming once and then
`reestablish_network/2` brings the same PAN back and paired devices re-attach
(exercised live against a ZBT-2 and in the adapter test suite).

## Supported dongles

Any Silicon Labs EmberZNet dongle running Zigbee NCP (EZSP) firmware. Only the
ZBT-2 has been exercised end-to-end so far; the others speak the same EZSP protocol
and should work (pass the right `:speed`), but are untested here.

| Dongle | Radio | Status |
| --- | --- | --- |
| Home Assistant Connect **ZBT-2** | EFR32MG24 | ✅ Verified (EmberZNet 7.5.1.0, 460800 baud) |
| Home Assistant SkyConnect / ZBT-1 | EFR32MG21 | ⚙️ Should work (EZSP), untested |
| Sonoff ZBDongle-**E** | EFR32MG21 | ⚙️ Should work (EZSP), untested |
| SMLIGHT SLZB-06/07 | EFR32 | ⚙️ Should work (EZSP), untested |
| Home Assistant Yellow | EFR32MG24 | ⚙️ Should work (EZSP), untested |
| Sonoff ZBDongle-**P**, CC2652 sticks | TI CC2652 | ❌ Not currently supported (Z-Stack) |
| ConBee / RaspBee | n/a | ❌ Not currently supported (deCONZ) |

TI Z-Stack and deCONZ radios aren't supported yet: they speak a different NCP
protocol, so each needs its own `Zigbee.Adapter` backend (see
[Writing a new backend](#writing-a-new-backend)). PRs welcome.

The ZBT-2 ships as a Zigbee coordinator. If yours has been flashed to Thread/Matter,
reflash the Zigbee NCP image.

## Architecture

The stack is split by the `Zigbee.Adapter` behaviour, so the chip-specific parts are
swappable and the application layer never sees a chip-specific frame:

```
Zigbee                     backend-agnostic facade (start_link/form/send_aps/…)
Zigbee.ZCL · Zigbee.ZDO    pure Zigbee spec codecs, work with any backend
Zigbee.Interview           join → interview → bind → report orchestration
Zigbee.Message             normalized inbound APS message
─────────────────────────  ▲ everything above depends only on the behaviour
Zigbee.Adapter             the behaviour (contract) + %Zigbee.Adapter{} handle
─────────────────────────  ▼ backends implement it
Zigbee.EZSP.Adapter        Silicon Labs EmberZNet backend
  ├─ EZSP                  EmberZNet Serial Protocol (frame IDs, EmberStatus)
  ├─ ASH                   Asynchronous Serial Host framing
  └─ Diagnostics           dongle probing helpers
```

- `Zigbee.ZCL` / `Zigbee.ZDO` are chip-agnostic codecs. The Zigbee
  specification defines these frames identically regardless of radio.
- `Zigbee.EZSP.Adapter` owns the dongle, runs the EmberZNet-specific coordinator
  sequence, and normalizes NCP callbacks into `{:zigbee, _}` events.

## Writing a new backend

To support another radio family (e.g. TI Z-Stack), implement `Zigbee.Adapter` in a
new module (say `Zigbee.ZNP.Adapter`): own the serial link, implement the callbacks
(`form_network`, `send_aps`, and so on), and emit the same normalized events.
`Interview`, `ZCL` and `ZDO` don't change. This is the
[zigpy](https://github.com/zigpy/zigpy) model (a chip-agnostic core plus `bellows`,
`zigpy-znp`, and `zigpy-deconz` radio libraries).

See `Zigbee.MockAdapter` (in `test/support`) for a minimal, hardware-free reference
implementation.

## Status

Codecs (`ZCL`, `ZDO`, `EZSP.Frame`, `ASH`) are unit-tested; `Zigbee.EZSP.Adapter`
has integration tests that drive form / reestablish / permit-join / join-handling /
incoming-decode against a fake NCP (`Zigbee.FakeEZSP`, injected via the `:ezsp`
option); and `Interview` is tested end-to-end against the in-memory
`Zigbee.MockAdapter` (no hardware).

Live against a ZBT-2 on EmberZNet 7.5.1.0, the full flow is verified end-to-end:
form / reestablish, pairing, interview, bind + configure-reporting, and decoding
temperature, humidity, and button events from real Aqara end-devices (Climate
Sensor W100, Wireless Mini Switch T1, Temperature & Humidity Sensor T1).

## Testing

```sh
mix test
```
