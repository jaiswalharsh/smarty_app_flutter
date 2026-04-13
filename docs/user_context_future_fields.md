# User Context — Future Structured Fields

v1 of **User Context** (see `lib/screens/user_context_page.dart`) intentionally ships
as a single free-form UTF-8 text box that is sent directly to Smarty's OpenAI system
prompt. The intent is to learn what parents actually type in before committing to a
schema.

This file is a parking lot for richer-schema ideas that came up during the v1 design
discussion. None of them are committed — they exist so we don't lose the thinking.

## Candidate fields

### Richer child profile
- Name
- Pronouns
- Age / date of birth
- Favorite characters (list)
- Interests / hobbies (list)
- Allergies and dietary notes
- Bedtime / wake time
- Timezone

### Parent / guardian info
- Parent/guardian name
- Preferred contact method
- Preferred conversation language (distinct from Smarty's TTS language)
- Content filter level

### Voice & personality
- TTS voice selection
- Smarty persona preset (e.g. "playful", "calm", "teacher")
- Response length preference (short / medium / long)
- Chattiness / talkativeness

### Safety & boundaries
- Topic allowlist / blocklist
- Max session length
- Quiet hours (per weekday)
- Per-device context (if one family has multiple Smarty devices)

## Design notes for when we come back to this

- The current BLE characteristic `0xAB03` is a single UTF-8 string capped at 500
  bytes. Moving to structured fields will require either:
  - a JSON payload on the same characteristic (simple, but eats more bytes per field
    because of key repetition), or
  - a set of sibling characteristics (e.g. `0xAB07`, `0xAB08`, …) — cleaner but
    bloats the GATT table.
- NVS on the ESP32 side currently uses one key `context` under namespace `user_ctx`.
  Structured fields would want either one NVS key per field or a single JSON blob.
- The OpenAI wiring at `openai_setup.c` currently injects the raw string. A
  structured approach would want a templating step (e.g. a Jinja-ish format) so
  the final system prompt is human-readable.
- Per-device context implies moving NVS storage from the BLE layer into a
  `user_context.c` module keyed by device identity, and making the Flutter side
  device-aware.

## Why we did not ship structured fields in v1

1. We do not yet know what parents will actually want to tell Smarty. A text box
   lets the real data drive the schema.
2. Every structured field adds a validation surface on Flutter, a parsing surface
   on ESP32, and a prompt-engineering surface in `openai_setup.c`. Premature.
3. A free-form string round-trips cleanly through NVS, BLE, SharedPreferences, and
   the OpenAI system prompt with almost no code. Structured fields do not.

Revisit after we have a handful of real parent-written contexts to look at.
