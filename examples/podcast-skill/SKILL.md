---
name: "podcast"
description: Generate and play a NotebookLM-style two-host audio podcast from a file, URL, or topic using the Voicebox MCP server. Use when the user runs /podcast or asks to "make a podcast", "turn this into audio", "read this as a conversation", or "give me an audio overview".
---

> **Configuration (optional)** — preferred voice profile names, if you have them:
> HOST_A = `Bella` (curious co-host, asks) · HOST_B = `Alloy` (expert, explains).
> Both are kokoro presets. If they don't exist, the skill auto-picks two profiles.
> Requires a running voice server on `127.0.0.1:17493` (default) — either
> [vocald](https://github.com/danylo-dudok/vocald) (headless: docker or
> `brew`-installed `vocald-server`) or the Voicebox desktop app. For a remote or
> authed vocald, export `VOICEBOX_API=<base url>` and `VOICEBOX_API_KEY=<key>`
> before running. macOS (`afplay`).

# podcast — local NotebookLM-style audio overviews

Turn the given source into a short two-host audio conversation and play it aloud
via vocald/Voicebox. Like NotebookLM's Audio Overview — no cloud, no upload, no leaving the terminal.

Two phases: **write the entire script first, then voice it.** Never interleave writing and
speaking — compose the whole episode up front so it's coherent, then render it turn by turn.

## How you are invoked

The user called you with a file path, a URL, or a topic, e.g.:
- `/podcast raw/some-article.md`
- `/podcast https://example.com/post`
- `/podcast the tradeoffs between Delta Lake and Iceberg`

## Steps

1. **Pick the two voices.** Call `list_profiles` (voicebox MCP tool, or `GET $VOICEBOX_API/profiles` — add `Authorization: Bearer $VOICEBOX_API_KEY` if the server enforces auth). If no profiles exist on a vocald server, create two kokoro presets first via the `create_profile` MCP tool (e.g. `af_bella`, `af_alloy`).
   - Use the Configuration names (HOST_A / HOST_B) if present; otherwise the first two distinct
     profiles — and tell the user which two. Note the profiles' engine (the helper defaults to `kokoro`).
   - Fewer than two profiles and `create_profile` unavailable (desktop app)? Stop and ask the user to create two in Voicebox → Voices, then rerun.

2. **Get the source.**
   - File path → read it with the Read tool.
   - URL → fetch it with WebFetch.
   - No argument → use the current conversation, or ask what the podcast should be about.

3. **Write the whole script first — in one pass.** Before voicing anything, compose the
   ENTIRE ~2–4 minute two-host dialogue as one ordered list of turns (each: speaker + text):
   - HOST_A is curious and asks; HOST_B is the expert who explains.
   - Conversational and warm — reactions, short asides, "so what that actually means is…".
     Not a lecture, not bullet points read aloud.
   - Open with a one-line hook, cover the 3–5 key ideas with concrete detail, end on the takeaway.
   - Keep each turn to 1–3 sentences.
   Print the finished transcript so the user sees the whole episode up front.

4. **Voice it — render each turn to a file, then play.** Do NOT use the live `speak` tool: it's
   async and overlapping turns play on top of each other. Instead, for each turn IN ORDER, run:

   ```
   bash ~/.claude/skills/podcast/scripts/say.sh "<profile>" "<turn text>"
   ```

   where `<profile>` is the HOST_A voice on HOST_A's turns and HOST_B on HOST_B's. The script
   renders the turn (`POST /generate`, `engine=kokoro`), downloads the clip (`GET /audio/{id}`),
   and plays it with `afplay` — which **blocks** until the clip ends, so turns stay in order with
   no overlap. Run the calls sequentially (wait for each to return); voice the script verbatim.

## Notes
- **Requirements:** a vocald server or the Voicebox app running, macOS (`afplay`), `python3`. No `ffmpeg` needed.
- **Remote/authed server:** export `VOICEBOX_API` (base URL) and `VOICEBOX_API_KEY` — `say.sh`
  sends the bearer automatically. Playback stays client-side (the server has no speakers).
- **Engine:** `say.sh` defaults to `engine=kokoro` (Bella/Alloy are kokoro presets; vocald only
  ships kokoro). For another engine on the desktop app, set `VOICEBOX_ENGINE`.
- **Keep the episode as one file (optional):** clips render to `/tmp/podcast_<id>.wav` and are
  deleted after playing. To save one file, drop the `rm`/skip cleanup and `ffmpeg`-concat the
  clips (if `ffmpeg` is installed).
