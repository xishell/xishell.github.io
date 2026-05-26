---
title: "Authentication doesn't belong on the sticker"
date: 2026-05-17
description: How the DockPulse adoption QR went from a COSE_Sign1 Ed25519 claim at version 17 down to plain SERIAL:HEX at version 3. The smaller QR was a side effect — the actual fix was that the signature was in the wrong place.
tags: [iot, qr, ble-mesh, dockpulse]
---

Each DockPulse sensor ships with a sticker. Operators scan it during
provisioning to bind the board to a specific berth. The first
version of that sticker was a COSE_Sign1 Ed25519-signed claim,
base45-encoded, sitting at QR version 17 (85×85 modules). The
shipping version is plaintext `SERIAL:HEX`, version 3 (29×29
modules).

The smaller QR is a side effect. The actual fix was realizing the
sticker was in the wrong place to authenticate anything.

## What the sticker started as

The original sticker payload was the European Digital COVID
Certificate recipe scaled down: a CBOR-encoded claim with the
device UUID, the OOB key, a JTI for replay protection, and an
expiry. Signed by a factory Ed25519 key, then base45-encoded so it
could go through a QR scanner without binary mode.

```
COSE_Sign1(claim) → base45 → ~190-char QR string
```

It worked. The backend held the public half of the factory key and
verified the signature on adoption. Forging a sticker required
gaining write access to the offline factory key — strong property.

Two problems:

- A v17 QR on a 25 mm round sticker is a dense code. A phone camera
  in mediocre dock lighting needs three tries.
- I was about to start managing a factory key. For a school
  project. Generation script, secure storage, distribution between
  team members, rotation when one of us inevitably committed it.

## The realization

The adoption flow does two things: it identifies *which* device
this is, and it authenticates that the device is *genuine*. I'd
put both jobs on the sticker.

A signed sticker is a credible identity proof, but it's not
authentication of the board. The board doesn't sign the claim; the
factory does. A photograph of the sticker is just as valid as the
original. The signature only proves "this row was issued by us at
some point" — not "the radio you're talking to right now is the
one the sticker belongs to."

Board authentication actually happens later, inside the BLE Mesh
PB-ADV handshake, using a static OOB key burned into the device's
`factory_nvs` partition at flash time. That OOB is the value an
attacker can't recover from a sticker photo.

So the sticker doesn't need to be unforgeable. It needs to be a
lookup key — like a HomeKit or Matter setup code: a name plus a
nonce.

## Dropping the signature

```
sticker = serial + ":" + jti
```

The backend stores `serial → {uuid, oob, jti, exp}`. Adoption is:

1. Scan sticker. Get `serial:jti`.
2. Look up row by `serial`.
3. Check `jti` matches, `exp` is in the future. (Replay protection.)
4. Run PB-ADV with the OOB. The board cryptographically proves it
   has the key.

A forged sticker fails at step 3 because the JTI won't match.
Photographing a real sticker and trying to adopt against a
different board fails at step 4 because the impostor board doesn't
have the OOB.

The signature would have proved step 1 came from us. PB-ADV proves
step 4 came from the right board. Step 4 is the harder property
and the one that matters. Step 1 was theatre.

This dropped 53 lines from `factory-flash.py`, deleted
`factory-keygen.sh` entirely, and removed the `cbor2` and `base45`
dependencies.

## Shrinking the QR further

Going from a signed blob to `SERIAL:UUID` cut the payload roughly
in half, but the QR was still bigger than I wanted because
`uuid4()` returns lowercase hex.

QR codes have four encoding modes. Numeric, alphanumeric, byte, and
Kanji. Alphanumeric is roughly 5.5 bits/char versus byte mode's 8
bits/char — a 30% size advantage — but its character set is only
`0-9`, `A-Z`, space, and `$%*+-./:`. Lowercase letters aren't in
the set. A lowercase UUID forces byte mode.

```python
-jti = str(_uuid.uuid4())
+jti = secrets.token_hex(8).upper()
```

`secrets.token_hex(8)` gives 16 hex chars; `.upper()` puts them in
the alphanumeric set. 64-bit collision probability hits 50% around
`2^32` stickers — past anything DockPulse will ship. The serial
format was already uppercase (`DP-N-000123`), so the full payload
encodes cleanly in alphanumeric mode:

```
DP-N-000123:7F3A9C2B1E4D5F60
```

29 characters, alphanumeric mode, version 3 QR at ECC level L.
Scans first try even in dock lighting.

## Where the security ended up

Nothing got weaker. The auth boundary moved from "operator scans a
signed sticker" to "operator scans a lookup key, board proves
itself at PB-ADV." The cryptographic property that actually matters
— that a stranger can't pretend to be your sensor — is unchanged.
What I removed was security theatre I'd built around the wrong
boundary.

I keep thinking about how much code that misplacement cost: a CBOR
library, a base45 library, an Ed25519 keypair, a key-management
script, 53 lines of signing code, and 14 QR versions of sticker
real estate. All to protect a value the backend was about to look
up anyway.
