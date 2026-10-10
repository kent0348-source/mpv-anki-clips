# Forvo vocabulary audio

Forvo lookup is optional and disabled by default (`use_forvo=no`). When enabled, MPV Anki Clips looks up pronunciation audio for the vocabulary value being exported and writes it to the configured audio field.

Configure these settings in the core settings file:

- `use_forvo=no`: disable lookup.
- `use_forvo=yes`: look up audio only when the configured vocabulary audio field is empty.
- `use_forvo=always`: look up audio even when the vocabulary audio field already has a value.
- `vocab_field`: field containing the vocabulary term to look up.
- `vocab_audio_field`: field to receive the pronunciation audio.

Set the field names to match your Anki note type. The shipped [core settings example](../src/mpv-anki-clips/exampleconfig/mpv-anki-clips-core.conf) has example values.

Lookup is skipped if the configured vocabulary field is empty or the audio field is not configured as a text field. If the vocabulary audio field is the same as the sentence-audio field, the fetched pronunciation is prepended to the generated audio content to avoid discarding it.
