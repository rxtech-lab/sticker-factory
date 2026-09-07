# WhatsApp and Telegram packs

Every pack under **Sticker Packs** can be sent to WhatsApp or Telegram from its own screen
(`PackDetailView`), by the two buttons above *Add to library* / *Edit pack*. Creating a pack lands
on that screen, so a new pack can be sent straight away. There is no separate settings page; the
only device-local state is the emoji chosen per sticker (`MessengerEmojiStore`).

## Where the encoding happens

The messenger copies of a sticker — a 512 px WebP for WhatsApp, a PNG or VP9 WebM for Telegram —
are made **once, on the creator's phone, when the pack is saved**, and uploaded as
`messengerWhatsApp` / `messengerTelegram` assets bound to the sticker's active revision
(`POST /stickers/:id/messenger-renditions`). Everyone who later opens the export sheet only
downloads them.

The run lives on one screen, `MessengerPreparationView`, driven by `MessengerRenditionPreparer`
(owned by `MarketplaceStore`):

- **New pack** (`PackComposerView`): after *Create and publish* / *Save as draft*, any member still
  missing a rendition pushes the conversion screen. The composer hands the pack to the caller only
  when that screen is left.
- **Edit pack** (`PackEditorView`): *Save* does the same after the edit lands. A pack whose members
  are unprepared but otherwise unchanged gets a *Prepare for WhatsApp and Telegram* button, since
  Save is a no-op without an edit. Either way the editor closes when the conversion screen does.
- The conversion screen has no back button and cannot be swiped down. **Cancel** stops the run
  where it is (whatever landed stays; the next save picks up the rest) and **Done** appears when
  the run finishes. Every member is listed with what became of it — "Ready for WhatsApp and
  Telegram", or the messenger's reason when its ceiling could not be met.
- Nothing encodes in the background. The pack screen shows the creator a notice when members are
  unprepared and sends them to the editor; the export sheet lists such members under *Not included*.

A member added to a second pack is free (both files already exist), and a sticker re-published
after its artwork was edited has to be prepared again, because the renditions hang off the
revision that was published.

## How a pack is cut

Both messengers refuse a pack that mixes still and animated stickers, and both cap the count, so
`MessengerPackSplitter` turns one pack into:

- one part per kind (`Cozy Cats · Static`, `Cozy Cats · Animated`), only when both kinds are present;
- balanced runs no longer than the cap (`(1/2)`, `(2/2)`) — 31 WhatsApp stickers become 16 + 15,
  never 30 + 1;
- a *Not included* list for anything that cannot go: fewer than three of a kind for WhatsApp, a
  member with no published artwork, or one not yet prepared for that messenger.

| | WhatsApp | Telegram |
|---|---|---|
| stickers per pack | 3–30 | 1–120 |
| canvas | 512 × 512 | 512 × 512 |
| still | WebP ≤ 100 KB | PNG ≤ 512 KB |
| animated | animated WebP ≤ 500 KB, ≤ 10 s, ≥ 8 ms/frame | VP9 WebM with alpha ≤ 256 KB, ≤ 3 s, ≤ 30 fps |
| tray / thumbnail | 96 × 96 PNG ≤ 50 KB (generated) | none |
| pack name | editable here | asked for in Telegram |

The export sheet starts downloading the prepared files the moment it opens — there is no *Start
export* step, because nothing is encoded there any more. Each part is handed over on its own —
`whatsapp://stickerPack` and `tg://importStickers` each take one pack off the pasteboard — so the
sheet gives every part its own button and reports a hand-off, not an install. Nothing comes back
from the messenger.

## Rendering

`MessengerStickerRenderer` reads the sticker's preview asset (the 1024 px master PNG, or the
sharing APNG at the document's frame rate; the system rendition as a fallback), fits it into a
transparent 512 px square and encodes for the destination. Size limits are met by walking a
ladder — quality first, then frame rate — and never by shrinking the canvas. An animation longer
than the messenger allows is **sped up** (`MessengerAnimationSchedule`), never cut. A sticker that
cannot fit at the bottom of the ladder is reported with its best size on the conversion screen;
the export sheet later lists it under *Not included* for that messenger and sends the rest.

Encoders:

- WebP — the existing `WebPEncoder` (libwebp).
- PNG — `UIImage.pngData`, then `IndexedPNGEncoder` palettes if a still is over Telegram's limit.
- VP9/WebM — `packages/VP9Encoder`: libvpx built from a pinned tag by
  `scripts/build-libvpx.sh` (VP9 only, BSD, no GPL/nonfree, no FFmpeg) plus a Swift EBML muxer.
  Alpha travels as a second VP9 stream in each block's `BlockAdditional`, the layout FFmpeg writes
  for `yuva420p` and Telegram decodes.

The WhatsApp hand-off is `packages/WASticker`, adapted from WhatsApp's BSD-licensed sample. The
Telegram hand-off is `TelegramStickersImport` via Swift Package Manager, pinned to a revision (the
repository has no tags). Both schemes are declared in `LSApplicationQueriesSchemes`.

## Tips and feature cards

`MessengerExportTip` is a TipKit popover on the messenger row itself, so the first pack a reader
opens says what the two buttons do. It is one tip for both buttons — two popovers over one row
would each cover the other's button — it follows the same `welcomeCompleted` rule as the rest of
the onboarding tips, shows once, and is invalidated the moment either button is tapped. TipKit is
not configured at all under UI automation.

`FeatureAnnouncement.all` lists what's-new cards with permanent ids; `FeatureAnnouncementStore`
keeps the acknowledged ids in `UserDefaults`, independent of app version and sign-in. Unread
cards are shown after the welcome tour (or on launch when the tour is not due); each **Next** /
**Got it** acknowledges only the card it was tapped on. Under UI automation they are suppressed
unless launched with `--ui-show-feature-cards`.

## Tests

- `FeatureAnnouncementTests` — stable ids, individual acknowledgement, appended cards, persistence.
- `MessengerPackSplitterTests` — kind grouping, balanced runs, per-messenger limits, minimums,
  exclusion, per-messenger preparation.
- `MessengerRenditionPreparerTests` — prepared members are skipped, one messenger's failure does
  not cost the other, idempotency keys survive a retry, cancellation.
- `MessengerAnimationScheduleTests` — acceleration, thinning, loop hold.
- `MessengerStickerRendererTests` — dimensions, byte limits, duration, transparency, checked by
  ImageIO (PNG/WebP) and by an EBML reader plus libvpx's decoder (WebM).
- `packages/VP9Encoder` tests — encoder round trip through the independent reader and decoder.
- UI tests — tab rename, the buttons on the pack screen, the conversion screen after creating and
  after editing a pack, the export sheet's not-installed and skipped states, and the feature cards
  after the tour.

Sending to the real apps has to be checked on a physical phone with WhatsApp and Telegram
installed; the simulator has neither.
