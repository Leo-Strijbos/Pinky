# Pinky

Pinky is a macOS menu bar companion that watches your screen, walks you through workflows step by step, and turns what you do into reusable skill files. Teach it a process on your screen, then ask it to guide you through that workflow later — or export the result as a skill file for other AI tools.

![Pinky — an ai buddy that lives on your mac](pinky-demo.gif)

## What it does

- **Teach workflows on your screen** — click **Teach me**, perform the steps, and Pinky captures what you do.
- **Convert workflows into skill files** — finished teaching sessions compile into local `.md` skill files with frontmatter, triggers, and step-by-step instructions.
- **Guide you through saved workflows** — ask Pinky to walk you through a saved skill and it points at UI elements while you work.
- **Voice + vision** — hold **Control + Option** to talk; Pinky sees your screen and can point at things across multiple monitors.

## Setup

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker; the Worker talks to the APIs. Your keys never ship in the app binary.

```bash
cd worker
npm install
```

Add your secrets (Wrangler will prompt you to paste each one):

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

Set your ElevenLabs voice ID in `wrangler.toml` (not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy:

```bash
npx wrangler deploy
```

Copy the deployed URL (for example `https://clicky-proxy.your-subdomain.workers.dev`).

### 2. Point the app at your Worker

Update the hardcoded Worker URL in the Swift app:

- `leanring-buddy/CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

Search for `clicky-proxy` or `workers.dev` to find every reference.

For local Worker development, run `npx wrangler dev` in `worker/` (usually `http://localhost:8787`) and create `worker/.dev.vars` with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Point the Swift URLs at `http://localhost:8787` while developing.

### 3. Build and run in Xcode

```bash
open leanring-buddy.xcodeproj
```

1. Select the `leanring-buddy` scheme
2. Set your signing team under **Signing & Capabilities**
3. Press **Cmd + R**

The app appears in the menu bar (not the Dock). Open the panel, grant permissions, click **Start**, then try **Teach me** to record a workflow.

### Permissions

- **Microphone** — push-to-talk voice capture
- **Accessibility** — global keyboard shortcut (Control + Option)
- **Screen Recording** — screenshots when you use the hotkey
- **Screen Content** — ScreenCaptureKit access

## Architecture

For the full technical breakdown, read `CLAUDE.md`. Short version:

**Menu bar app** with two `NSPanel` windows — a control panel and a full-screen transparent cursor overlay. Push-to-talk streams audio to AssemblyAI, sends transcript + screenshot to Claude via streaming SSE, and plays responses through ElevenLabs TTS. Claude can embed `[POINT:x,y:label:screenN]` tags to animate the cursor to UI elements. Teaching mode captures screen context and compiles workflows into local skill files. All external APIs are proxied through the Cloudflare Worker.

## Project structure

```
leanring-buddy/          # Swift source
  CompanionManager.swift    # Central state machine
  SkillWriter.swift           # Workflow → skill file export
  SkillManager.swift          # Teaching + skill storage
  OverlayWindow.swift         # Cursor overlay
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Routes: /chat, /tts, /transcribe-token
CLAUDE.md                # Full architecture doc
```

## License

MIT — see [LICENSE](LICENSE).
