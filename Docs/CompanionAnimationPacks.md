# Companion animated character packs

Companion accepts a local `.json` file containing a raster sprite sheet and
playback metadata. Choose **Import animated character…** in Companion's appearance
controls, preview each state, then choose **Use this character**. Cancel leaves
your existing character unchanged. Import is local and does not need a provider.
The selected character belongs to the existing saved agent and survives relaunch;
it does not create a profile, conversation, permission, or execution engine.

## Format

```json
{
  "version": 1,
  "name": "My companion",
  "image": "BASE64_ENCODED_TRANSPARENT_PNG_OR_WEBP",
  "animations": {
    "idle": { "row": 0, "frameCount": 6, "frameMilliseconds": 125 },
    "greeting": { "row": 1, "frameCount": 4, "frameMilliseconds": 125 },
    "working": { "row": 2, "frameCount": 6, "frameMilliseconds": 125 },
    "listening": { "row": 3, "frameCount": 6, "frameMilliseconds": 200 },
    "speaking": { "row": 4, "frameCount": 6, "frameMilliseconds": 125 },
    "approval-needed": { "row": 5, "frameCount": 6, "frameMilliseconds": 250 },
    "completion": { "row": 6, "frameCount": 5, "frameMilliseconds": 125 },
    "failure": { "row": 7, "frameCount": 8, "frameMilliseconds": 125 }
  }
}
```

The image is inline standard base64, without a `data:` prefix. Rows are numbered
from zero at the top. Frames begin in the leftmost cell of a row. Frame durations
are constant within each animation. Idle is required; all other states fall back
to the complete idle animation if omitted. A state may reuse another state's row.
The importer rejects unknown state names and unknown top-level properties.

- Eight columns, each cell **192 × 208 pixels**; sheet width **1536 pixels**.
- One to thirteen rows; height is a positive multiple of **208**, at most **2704**.
- One to eight populated frames per referenced row. Referenced frames must contain
  visible artwork. PNG and WebP must have an alpha channel.
- Each frame lasts **50–2000 milliseconds**.
- Name: **1–80 characters**. Format version: **1**.
- Image source: at most **20 MiB**. Whole JSON: at most **28 MiB**.
- Decoded sheet: at most **16 MiB** of RGBA pixels. The import preview displays
  dimensions, decoded sheet memory, image size, and missing-state fallbacks.

Use consistent cell positioning across all poses. Rendering measures one common
transform for the entire sheet so poses retain their relative size and position.
Artwork and metadata are the entire format: no URLs, external paths, archives,
scripts, model prompts, or executable extensions are accepted or evaluated.

Playback follows real task state. Listening starts after microphone capture
starts; speaking follows audio playback. Built-in packs without those animations
show idle art with the corresponding accessible microphone/speaker badge.
Greeting and completion play once; ordinary activity loops. Reduce Motion freezes
the image, while status text and badges remain visible. Hidden or closed windows
stop animation. Desktop mode may animate while another application is active.
Only the right Companion tab responds to the pointer; imported packs currently
have no directional gaze metadata and stay neutral.

## Desktop and voice

Choose **Desktop companion** to show or hide the movable panel. Its options allow
64, 80, 112, or 144 point characters (80 points by default) and an optional **Always on top** setting.
The right tab keeps its independent 80 point character. Drag near a screen edge
to snap; window position is restored and kept within the available screen.
**Control–Option–Command–C** summons or hides the panel while Locus is running.
If another app owns that shortcut, the options show that it is unavailable.

Click the desktop character or **Chat** to expand the same Companion conversation.
Typing and clearing use the same draft and durable chat as Locus. **Talk with
companion** uses the existing Voice settings. Hold the microphone button or its
focused Space key to record, release to finish, or click to toggle. The microphone
indicator shows actual recording; **Stop speaking** interrupts playback. Existing
review-before-send, microphone permission, speech recognition, and provider
settings still apply. Closing the voice controls or deactivating Locus stops an
active recording; audio is never captured just by showing the character.
