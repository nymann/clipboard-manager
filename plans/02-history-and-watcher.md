# 02 — History store + pasteboard watcher

Capture plain-text clips into a capped, de-duplicated in-memory ring.

## Pre-conditions

- Plan 01 landed; `just build` green; status item shows.

## Steps

1. `History`: `private(set) var items: [String]`, `cap = 200`.
   `add(_:)` trims the string, ignores empty, removes any existing
   equal entry, inserts at index 0, evicts past `cap`. `clear()`.

2. Pasteboard watcher on a 0.5 s repeating `Timer`:
   - Track `lastChangeCount`.
   - On `NSPasteboard.general.changeCount` change: skip if `types`
     contains `org.nspasteboard.ConcealedType` or
     `org.nspasteboard.TransientType`; else read
     `string(forType: .string)` and `History.add` it.
   - Expose `markPasteboardWritten()` to set `lastChangeCount` to the
     current count so a self-write isn't re-ingested.

3. Right-click status menu: disabled "N clips" header, "Clear
   History", "Quit". Left-click is wired in plan 03/04.

## Verification

- Copy text in several apps → menu count rises; re-copying an existing
  clip doesn't grow the count.
- Copying from a password manager (concealed) does not add a clip.
- `swiftc -typecheck` passes.

## Commit

`feat: in-memory clip history + pasteboard watcher`
