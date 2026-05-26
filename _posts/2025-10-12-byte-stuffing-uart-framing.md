---
title: "Byte stuffing won't save you from a missed SYNC"
date: 2025-10-12
description: Notes from the crypt-chat framer on a bit-banged RISC-V UART. Why the framer needed a per-frame timeout, and what I almost forgot to stuff.
tags: [embedded, riscv, uart, crypt-chat]
---

The crypt-chat protocol uses a two-byte SYNC (`0xAA 0xAA`) followed by
a length byte and a stuffed payload. I picked `0xAA` because it's
alternating bits in binary — easy to recognize on a scope and unlikely
to appear by accident in ASCII.

The framer's job is small: walk the UART RX ring, find SYNC, read the
length, read that many bytes, check CRC16-CCITT, deliver. The first
version had no timeout. The first version also locked up the receiver
the first time anything went wrong on the wire.

## What broke

When a single bit flipped inside the SYNC pattern, the framer
half-matched: it saw one `0xAA`, the next byte didn't match, so it
restarted the search from the byte after the failed match. So far so
good. But when the *next* `0xAA` arrived followed by garbage that
happened to look like a plausible length (say `0x07`), the framer
committed: now it was waiting for seven bytes that were never coming,
because the real next frame was somewhere downstream.

No external signal said "this frame is dead." The state machine just
sat there, indefinitely, with the RX ring filling up behind it.

## The fix is the usual one

A per-frame timeout. About one second, conservatively. Long enough that
a slow sender on a busy link doesn't get dropped, short enough that a
single dropped byte doesn't deadlock the receiver for the entire run.

```c
// in the framer, between byte reads
if (now_ms() - frame_start_ms > FRAME_TIMEOUT_MS) {
    state = LOOKING_FOR_SYNC;
}
```

Once that landed, the framer recovered from any single corruption
within one timeout window. Cheap.

## Stuffing, and the bytes I forgot to stuff

Two reserved bytes:

```
0xAA → 0xAB 0x00
0xAB → 0xAB 0x01
```

`0xAA` is the SYNC marker, `0xAB` is the escape. Any payload byte that
would otherwise look like one of those gets expanded. The parser
unstuffs on the fly while it walks the frame.

What I almost shipped: stuffing only the message bytes, not the CRC.
The CRC is computed over `USER_ID + MESSAGE`, then appended as two
bytes. If those two bytes happened to contain `0xAA` — and CRC bytes
are uniformly distributed, so this happens about 1 in 128 frames — the
SYNC marker would appear in the middle of the frame, and the next
frame's parse would start in the wrong place.

CRC bytes go through the stuffer too. Obvious in retrospect, missed it
the first time.

## RX is interrupt-driven, framer isn't

The bit-banged UART has no hardware support, so RX is interrupt-driven:
a falling edge on the RX pin fires the ISR, the ISR samples mid-bit at
`1/baud + 0.5/baud` intervals, and the assembled byte goes into a ring
buffer. The main loop drains the ring into the framer.

The thing that surprised me: with the ISR handling per-bit sampling,
the framer itself can be as slow as it wants. The hard real-time
constraint lives entirely inside the ISR, where missing a sample by a
few microseconds gives you a wrong byte. Everything downstream of the
ring buffer is soft real-time and that simplified the whole design.

## What I'd change next time

If I do framing over a less polite physical layer:

- Use a longer SYNC. Two bytes is enough on a clean cable. On a shared
  or noisy line, four is cheap insurance.
- Stuff the length byte too. Currently `LEN` is the count of unstuffed
  bytes, which is what the application wants, but means the framer
  reads "post-stuffing length minus stuffing escapes" — easy to
  misread.
- Add a sequence number. Without one, a retransmit is
  indistinguishable from a deliberate duplicate.

The chat runs over a clean UART so none of those matter today. They're
notes for the next physical layer that isn't polite.
