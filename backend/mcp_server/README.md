# mcp_server

FastMCP server mounted at `/mcp` on the main FastAPI app (Streamable HTTP
transport). Same auth as REST: send `Authorization: Bearer <VOICEBOX_API_KEY>`
when the server enforces a key.

Client config (Claude Code `.mcp.json`, Cursor, etc.):

```json
{
  "mcpServers": {
    "voicebox": {
      "type": "http",
      "url": "http://127.0.0.1:17493/mcp",
      "headers": { "Authorization": "Bearer <key>" }
    }
  }
}
```

## Tools

| Tool | Purpose |
|---|---|
| `voicebox.list_profiles` | List voice profiles |
| `voicebox.create_profile` | Create a preset voice (kokoro voice ids) |
| `voicebox.generate` | Synthesize, wait, return `{generation_id, audio_url}` |
| `voicebox.speak` | Fire-and-forget synthesis; returns a poll URL |
| `voicebox.transcribe` | Audio (base64) → text via Whisper |
| `voicebox.list_captures` | Recent captures with transcripts |

Tool names keep the `voicebox.` prefix for compatibility with existing
clients. The stdio shim mentioned in upstream docs ships with the desktop
app only — this headless build is HTTP-native.
