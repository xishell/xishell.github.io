---
title: "The hashmap header lives at `entries[-1]`"
date: 2026-03-04
description: A C pointer trick from lwhttp's header map. The public type is Entry*, but the capacity and count live at entries[-1].
tags: [c, data-structures, http, lwhttp]
---

HTTP headers want a case-insensitive map. `Content-Type` and
`content-type` are the same header per RFC 9110 §5.1, so any reasonable
implementation lower-cases on hash and `strcasecmp` on collision.
Standard stuff.

What I wanted from the public API was something terser than a struct.
Callers shouldn't have to keep two pointers (`map` and `entries`)
threaded everywhere — they should have one opaque handle. So the
public type in [`lwhttp`](https://github.com/xishell/lwhttp) is just
`Entry *`:

```c
int   hm_set(Entry **entries, char *key, char *value);
char *hm_get(Entry *entries, char *key);
int   hm_delete(Entry *entries, char *key);
void  hm_destroy(Entry *entries);
```

No `Map` struct. One pointer to the entries array. So where does the
capacity live?

## At `entries[-1]`

The trick: allocate a `Header` struct *immediately before* the entries
array in the same `malloc` call, and return a pointer to the entries.
The caller never sees the header. The implementation walks one slot
backwards to find it.

```c
typedef struct {
    size_t count;
    size_t capacity;
} Header;

static Entry *hm_alloc(size_t capacity) {
    Header *header = calloc(1, sizeof(Header) + sizeof(Entry) * capacity);
    if (!header) return NULL;
    header->capacity = capacity;
    return (Entry *)(header + 1);   // hand out the entries pointer
}

static Header *hm_header(Entry *entries) {
    return (Header *)entries - 1;
}
```

`(Header *)entries - 1` is the pointer arithmetic that recovers the
header: cast the entries pointer to `Header *`, then back up by one
`Header`. That's exactly where `hm_alloc` placed it.

When the map needs to grow, `realloc` won't work directly because the
caller holds the entries pointer and we'd need to update it through
the double pointer:

```c
int hm_set(Entry **entries, char *key, char *value) {
    ...
    if (header->count * 4 >= header->capacity * 3) {
        if (hm_resize(entries) == -1) return -1;
        header = hm_header(*entries);  // re-fetch after resize
    }
    ...
}
```

`hm_set` takes `Entry **` so it can swap the pointer on resize; the
other functions take `Entry *` because they don't move the array.

## Why bother

For a struct-based map, the caller writes:

```c
Map *map = map_new();
map_set(map, "Content-Type", "application/json");
char *t = map_get(map, "Content-Type");
```

For this one:

```c
Entry *headers = NULL;
hm_set(&headers, "Content-Type", "application/json");
char *t = hm_get(headers, "Content-Type");
```

The handle has the same arity, but the type *is* the entries — there's
no opaque wrapper. For a library where the map is conceptually a header
table, that reads cleaner: `request->headers` is `Entry *`, and you
pass it around as-is.

The cost is the resize ergonomics — `hm_set` needs the double pointer.
You eat that once in the call site.

## Tombstones, not free-on-delete

Open-addressing maps with linear probing can't just mark a slot
`EMPTY` on delete, because the probe chain would terminate early when
searching for a key that lived past the deleted slot. The fix is a
third state, `DELETED`, that lookups skip and inserts can overwrite:

```c
enum slot_state { EMPTY, OCCUPIED, DELETED };
```

`hm_get` stops at `EMPTY` but continues past `DELETED`. `hm_set`
reuses the first `DELETED` slot it sees on the probe chain, but only
*after* it's confirmed the key isn't already present further down.
That confirm step is the trap: if you write to the tombstone too
eagerly, you can end up with two entries for the same key.

The probe loop in `hm_set` handles it like this:

```c
for (size_t i = 0; i < header->capacity; i++) {
    Entry *e = &(*entries)[idx];
    if (e->state == EMPTY) {
        if (first_insertable == (size_t)-1) first_insertable = idx;
        break;  // chain ends here, key definitely absent
    }
    if (e->state == DELETED) {
        if (first_insertable == (size_t)-1) first_insertable = idx;
    } else if (strcasecmp(e->key, key) == 0) {
        // overwrite existing
    }
    idx = (idx + 1) & (header->capacity - 1);
}
```

Track the first usable slot, keep probing past it until either the key
shows up or the chain ends. Only then commit the write.

## Hash and load factor

FNV-1a over the lowercased key, mask with `(capacity - 1)` because
capacity is always a power of two. Resize at 3/4 full. Nothing exotic:

```c
static uint64_t hm_hash(const char *key) {
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (const char *p = key; *p; p++) {
        hash ^= (uint8_t)tolower(*p);
        hash *= 0x100000001b3ULL;
    }
    return hash;
}
```

The lowercase happens during hashing so two-spellings of the same
header always hash to the same bucket. Collision check still uses
`strcasecmp` because the keys are stored in whatever case the caller
inserted with — I didn't want to lose the original capitalization
when iterating.

## When this is the wrong choice

The header-behind-entries trick is fun, but for a general-purpose
hashmap I wouldn't reach for it. Reasons:

- The handle's type leaks the implementation (`Entry *` says "open
  addressing"). A struct-based handle keeps the layout private.
- Generic key/value types are easier behind a struct.
- Debugging is slightly worse because gdb won't auto-pretty-print the
  header sitting at a negative offset.

For HTTP headers specifically — small map, fixed key/value types,
caller already thinks of "the headers" as a unit — it fits.
