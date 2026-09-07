# WASticker

WhatsApp's official third-party sticker hand-off, as a Swift package. Adapted from the
`WAStickersThirdParty` sample in https://github.com/WhatsApp/stickers under its BSD license
(`LICENSE`, `NOTICE`).

- `WAStickerLimits` — the sizes, counts and durations WhatsApp enforces.
- `WAStickerImage` / `WASticker` / `WAStickerPack` — the pack model, validated against those limits.
  Image facts are read through ImageIO rather than the sample's bundled WebP decoder.
- `WAStickerInteroperability` — puts the pack on the pasteboard and opens `whatsapp://stickerPack`.
  The host app must list `whatsapp` under `LSApplicationQueriesSchemes`.

Encoding to WebP is the host's job; this package only validates and sends.
