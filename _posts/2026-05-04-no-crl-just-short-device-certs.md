---
title: "No CRL, just 90-day device certs"
date: 2026-05-04
description: How DockPulse runs two parallel root CAs for an MQTT bus, and why short-lived device certs let me skip the revocation problem entirely.
tags: [pki, mqtt, iot, mtls]
---

DockPulse is a harbor berth monitoring system I worked on this
semester. The IoT side is a fleet of solar-powered ESP32 sensors and
mains-powered gateways talking to a mosquitto broker over mTLS. The
question I had to answer early: how do certs get issued, rotated, and
revoked when something goes wrong?

The setup I landed on:

- Service CA — backend services and dev publishers. Long-lived certs,
  825 days.
- Device CA — per-gateway and per-sensor certs. Short-lived, 90 days.
- mosquitto trusts the *bundle* (`cat service-ca/ca.crt device-ca/ca.crt > ca-bundle.crt`).
- No CRL, no OCSP stapling, no revocation infrastructure.

The interesting decision is the last one.

## Two parallel CAs, not one

The naive setup is one CA that signs everything. Works, but tangles
two very different fleets:

- **Services** are stable. Backend pods, dev publishers, the
  occasional load-test client. They get rotated when someone
  remembers to, which is rarely. Long-lived certs are fine because
  the operator (me) holds the broker config and can update
  CN-to-identity mappings when a cert reissues.
- **Devices** are unstable. Sensors fall in the water. Gateways get
  flashed by the wrong person. The keys live on ESP32 flash, not an
  HSM, so any device cert is one bad reflow away from compromise.

Different threat profile, different rotation cadence. Two parallel
CAs let me tune lifetimes independently and assign blame: a leaked
service key is an *operator* problem, a leaked device key is a *fleet*
problem. mosquitto doesn't care which CA signed a leaf — with
`require_certificate true` and a CA bundle file, it trusts both:

```
cafile /mosquitto/certs/ca-bundle.crt
require_certificate true
use_identity_as_username true
tls_version tlsv1.2
```

`use_identity_as_username true` is what makes the CN matter — the
cert's CN becomes the MQTT username for ACL purposes.

## 90-day device certs as poor-man's revocation

The honest reason for short-lived device certs: I didn't want to
operate a CRL.

A proper revocation story for a small fleet looks like:

1. Run a CRL distribution point.
2. Configure every broker to fetch and refresh the CRL.
3. When a device is compromised, add its serial to the CRL.
4. Wait for every broker to refresh.
5. Hope no client is caching a stale CRL.

For a school project with under twenty devices, that's a lot of
infrastructure. The web has dealt with the same problem by switching
to short certs and assuming clients will just wait for expiry. Let's
Encrypt issues 90 days; the same window happens to match what Apple
App Transport Security recommends.

So device certs get 90 days, and "revocation" means "stop trusting
this CN at the ACL level until the cert expires." Worst case: 90
days of a bad key being valid. Acceptable when the broker isn't
routable from the public internet.

In `tools/gen_certs.sh`:

```bash
DAYS_LEAF=825      # service clients
DAYS_DEVICE=90     # devices; matches LE cadence so we never need a CRL
```

The `device <node-id>` subcommand rotates by default — running it on
the same id deletes the prior cert and issues a fresh one. ESP-IDF
embeds the cert and key into the firmware image at compile time:

```cmake
target_add_binary_data(${COMPONENT_LIB} "${_dp_cert}" TEXT)
target_add_binary_data(${COMPONENT_LIB} "${_dp_key}"  TEXT)
```

Rotation = reissue + reflash. Same node-id, new cert. The broker
recognizes the CN, the ACL still binds.

## The ACL hole I left

The ACL uses `%u` (the username, which is the cert CN) to bind topics
to the connected client:

```
pattern read   dockpulse/v1/gw/%u/provision/req
pattern write  dockpulse/v1/gw/%u/provision/resp
```

A gateway with CN `gw-001` can only read its own `/provision/req`
and write its own `/provision/resp`. Clean isolation between
gateways at the broker level.

What I couldn't bind that way: berth telemetry. The topic shape is

```
harbor/{harbor_id}/{dock_id}/{berth_id}/status
```

no publisher id segment. The contract was set before I touched the
broker config, and changing it would have rippled across the backend,
the iOS prototype, and the visualization frontend.

So the ACL on telemetry is loose:

```
# Any device-CA client can publish; backend validates node_id in
# the payload.
pattern write  harbor/+/+/+/status
pattern write  harbor/+/+/+/heartbeat
```

A compromised device can publish telemetry as if it were any other
berth. The backend cross-checks `node_id` in the JSON against the
adoption table, so a fraudulent publish gets dropped — but at the
broker level there's nothing stopping it.

The honest cost of inheriting a topic schema. If I'd designed the
contract from scratch every topic would include the publisher id
segment. As built, the broker is a soft boundary and the backend is
the hard one.

## When this isn't enough

Two-CA-plus-short-device-certs holds up for a small private fleet.
What I'd add if the project grew:

- An actual CA hierarchy: offline root, online intermediate. Currently
  both CAs are self-signed roots — fine for trust but the root keys
  live on the same machine that signs leaves.
- A CRL distribution point or OCSP stapling, so revocation doesn't
  depend on someone reflashing a device.
- A topic schema with the publisher id baked in. The current ACL hole
  on telemetry is the single thing I'd push back on if I were
  starting over.

None of which I needed for twenty sensors and a graded deadline.
