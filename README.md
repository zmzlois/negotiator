# SmallTalk AI

Elixir-native multiplayer voice AI for live investor negotiation calls.

## what it does

You call a phone number. An AI agent picks up and asks if you want pitch practice or to call a real investor. In pitch practice, a simulated investor grills you on your startup. When you're ready for the real thing, give the investor's name, firm, and number — the app dials them, bridges the call, and becomes your live co-pilot.

During a live investor call:
- **DTMF 3** — mute yourself, enter private briefing. the negotiation coach whispers advice in your ear while the small talk agent continues the conversation with the investor in your cloned voice.
- **DTMF 4** — side-listen mode. the small talk agent keeps the investor engaged while you listen.
- **DTMF 5** — unmute and return to the call.

The small talk agent learns from every call. Everything you say is indexed into a per-founder knowledge base (keyed by your phone number). Next time you call, the agent already knows your company, your pitch, your numbers.

## architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PHONE CALL (Telnyx)                         │
│                                                                    │
│   founder phone ──► Telnyx Call Control ──► investor phone          │
│        │                    │                     │                 │
│        │              webhooks + media             │                │
│        ▼                    ▼                     ▼                 │
│   ┌─────────┐      ┌──────────────┐       ┌─────────┐             │
│   │ founder │      │   Elixir     │       │investor │             │
│   │ media   │◄────►│   App        │◄─────►│ media   │             │
│   │ socket  │ pcmu │              │ pcmu  │ socket  │             │
│   └─────────┘      └──────┬───────┘       └─────────┘             │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
   ┌─────────────┐  ┌───────────┐  ┌──────────────┐
   │ CallSession │  │  Memory   │  │   Desktop    │
   │ (GenServer) │  │  (ETS)    │  │   (Electron) │
   │             │  │           │  │              │
   │ state       │  │ transcript│  │ live call    │
   │ machine     │──│ context   │  │ status via   │
   │ + events    │  │ retrieval │  │ WebSocket    │
   │             │  │           │  │ /ws/calls    │
   └──────┬──────┘  └─────┬─────┘  └──────────────┘
          │               │
          ▼               ▼
   ┌──────────────────────────────────────────┐
   │            Provider Jobs (async)          │
   │                                          │
   │  ┌───────────┐  ┌──────────┐  ┌───────┐ │
   │  │ LLM       │  │ Voice    │  │Search │ │
   │  │ (OpenAI)  │  │ (11Labs) │  │(Brave)│ │
   │  └───────────┘  └──────────┘  └───────┘ │
   │  ┌───────────┐  ┌──────────┐            │
   │  │ Identity  │  │Retrieval │            │
   │  │ (OpenAI)  │  │ (Moss)   │            │
   │  └───────────┘  └──────────┘            │
   └──────────────────────────────────────────┘
```

### call flow

```
  founder calls ──► Telnyx answers ──► media streaming starts
                                            │
                                     ┌──────┴──────┐
                                     ▼             ▼
                              STT (Telnyx)    VAD (Silero)
                                     │             │
                                     ▼             ▼
                              transcription   end-of-turn
                                     │        detection
                                     ▼
                              ┌─────────────┐
                              │ CallSession  │
                              │              │
                              │ intent?      │──► "pitch practice" ──► practice mode
                              │              │──► "call investor"  ──► collect identity
                              │              │                         ──► dial + bridge
                              └──────┬───────┘
                                     │
                    ┌────────────────┬┴───────────────┐
                    ▼                ▼                ▼
             SimulatedInvestor  SmallTalkAgent  NegotiationAgent
             (practice mode)   (briefing/       (private coach)
                               agent takeover)
                    │                │                │
                    ▼                ▼                ▼
               LLM + TTS       LLM + TTS        LLM + TTS
               (investor       (founder's        (coach voice
                voice)          cloned voice)     to founder)
                    │                │                │
                    ▼                ▼                ▼
              ──────────── phone audio ────────────────
```

### rooms and modes

```
  NORMAL (pitch practice)          BRIEFING (DTMF 3)           AGENT TAKEOVER (DTMF 4)
  ┌─────────────────────┐   ┌──────────────────────────┐   ┌─────────────────────────┐
  │ main room           │   │ main room                │   │ main room               │
  │                     │   │                          │   │                         │
  │ founder ◄──► investor│   │ small_talk ◄──► investor │   │ small_talk ◄──► investor│
  │ (both hear)         │   │ (cloned voice)           │   │ (cloned voice)          │
  │                     │   │                          │   │                         │
  └─────────────────────┘   │ briefing room            │   │ founder listens to      │
                            │                          │   │ both rooms              │
                            │ founder ◄── coach        │   │                         │
                            │ (private, investor       │   └─────────────────────────┘
                            │  cannot hear)            │
                            └──────────────────────────┘
```

### data flow: transcript → knowledge

```
  speech turn recorded
       │
       ├──► SQLite (transcript_turns table)
       │         durable, queryable history
       │
       ├──► MossSession (local, per-call)
       │         in-memory semantic index
       │         queried by retrieval_refresh after each turn
       │         results cached in Memory.retrieval_context
       │
       ├──► TranscriptIndexer ──► Moss cloud (conversation index)
       │         cross-call transcript persistence
       │
       └──► on call end: push to Moss cloud (founder:{phone} index)
                 per-founder knowledge that grows across calls
                 loaded on next call start
```

## setup

### prerequisites

- Elixir 1.15+ / OTP 26+
- Telnyx account with Call Control app + phone number
- ElevenLabs API key + cloned voice
- OpenAI API key (for investor identity extraction)
- Moss project (for semantic retrieval)
- Brave Search API key (for live research tools)
- ngrok or similar tunnel for Telnyx webhooks

### install

```sh
mix deps.get
mix ecto.create
mix ecto.migrate
```

### configure

create `.env` with:

```sh
TELNYX_API_KEY=...
TELNYX_CONNECTION_ID=...
TELNYX_PHONE_NUMBER=+1...
TELNYX_PUBLIC_KEY=...

PUBLIC_BASE_URL=https://your-tunnel.ngrok-free.dev
PHONE_NUMBER=+1...
STAFF_PHONE_E164=+1...

MOSS_PROJECT_ID=...
MOSS_PROJECT_KEY=...
MOSS_INDEX_NAME=negotiation-bank
MOSS_CONVO_INDEX_NAME=conversation

OPENAI_API_KEY=...
ELEVENLAB_API_KEY=...
ELEVENLABS_VOICE_ID=...
FOUNDER_VOICE_ID=...
INVESTOR_VOICE_ID=...

WEB_SEARCH_API_KEY=...

LOG=1
```

point your Telnyx Call Control webhook at:

```
https://your-tunnel.ngrok-free.dev/telnyx/webhook
```

### run

```sh
# start the app
NEGOTIATOR_HTTP_ENABLED=1 mix run --no-halt

# or with the dev helper (starts ngrok + app)
mix negotiator.dev
```

### desktop app

```sh
cd desktop
npm install
npm run dev
```

the desktop app connects to `ws://127.0.0.1:4000/ws/calls` and shows live call status, transcript, coaching, and mode transitions.

## usage

1. **call the Telnyx number** from your phone
2. the agent answers: "are you here for pitch practice or do you want to call an investor?"
3. say **"pitch practice"** — a simulated investor starts evaluating your startup
4. say **"call investor"** — the agent asks for investor name, firm, and phone number, then dials and bridges

during a live investor call:
- **press 3** — mute yourself, get private coaching, small talk agent takes over with your cloned voice
- **press 4** — side-listen while the agent keeps the conversation warm
- **press 5** — return to the call

## code layout

```
lib/negotiator/
├── agents/          small_talk, negotiation coach, simulated investor
├── call_tree/       call session state machine, speech, orchestration
├── llm/             LLM adapters (OpenAI, MiniMax), tool calling, TTS
├── memory/          ETS call state, Moss sessions, transcript store, retrieval
├── prompt/          system prompts for each agent role
├── silero_vad/      on-device end-of-turn detection
├── supervisor/      OTP supervision, providers, runtime status
├── telephony/       Telnyx webhooks, call control, media websockets
├── tools/           web search, research, external boundaries
└── voice/           audio format conversion, phone output

desktop/             Electron + React observer app (read-only)
```

## key modules

| module | role |
| --- | --- |
| `CallSession` | GenServer state machine for one call — modes, events, orchestration |
| `Memory` | ETS-backed shared state — single write path via `Memory.write/2` |
| `MossSession` | per-call local Moss index for semantic transcript search |
| `SimulatedInvestor` | pitch practice mode — LLM-driven investor with tool calling |
| `SmallTalkAgent` | founder's cloned voice — keeps investor engaged during briefing |
| `NegotiationAgent` | private coach — tells founder what to say and what not to concede |
| `ProviderJobs` | async task runner for LLM, TTS, retrieval, research |
| `ToolDefs` / `ToolExecutor` | LLM function calling — web search, verify claims, unit economics |
| `InvestorIdentity` | extracts investor name/firm/number from speech via OpenAI |
| `Orchestration` | room topology — who hears what in each mode |

## tool calling

the simulated investor has access to live tools during pitch practice:

| tool | what it does |
| --- | --- |
| `web_search` | search Brave for market data, verify claims |
| `verify_claim` | fact-check founder's stated metrics |
| `competitor_lookup` | deep dive on a named competitor |
| `calculate_unit_economics` | compute CAC payback, LTV/CAC, runway, dilution |
| `search_recent_news` | find recent events for curveball questions |
| `moss_search` | search call transcript for what was said earlier |

the negotiation coach and small talk agent can use `moss_search` and `web_search`.
