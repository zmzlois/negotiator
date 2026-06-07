# Repo rules

# Goal

This is a multiplayer negotiation agent. 

A turborepo with nextjs frontend, desktop app and elixir backend. 

This is a multiplayer negotiation helper system built on Elixir. I can call an angel investor (via phone number provided by Telnyx) and ask them to invest me 500k, while I get nervous, i press 3 on my phone DTMF, open a break out room,
 
1. negotiation briefing room: me and the negotiation agent, the negotiation agent use moss to know how should i be continue talking because i am panicking, and it has a bank of knowledge about negotiation techniques
2. small talk room: investor and the small talk agent, the small talk agent would sounds like me and continue the conversation with the other party while i am figuring out what to say. 

both agent need to be fully aware of the entire conversation, and both agent knows what exactly happened in each room and what conversation has happened, 

once i am ready to continue the conversation the breakout room would join back together, small talk agent is muted while the other party is talking and let me be back to the conversation when i am ready, or i can side listen to the small talk agent to finish the conversation to seal the 500k deal after pressing 4

I want to jump ahead before end of turn as well because end of turn models are usually not accurate, i want answers from each agents are predicted based on every three words, like queued up answers A | B | C | D | E before i even finish the conversation

while i am developing locally I also need the ability to replace any role that are human in the conversation because i am just developing by myself

## Agent roles

There are two separate AI agents in this system. Do not collapse them into one role.

1. `small_talk` is the public-facing voice agent. it should sound like me and keep pitching investors while i am muted, thinking, or getting help.
2. `negotiator` is the private negotiation agent. it helps me negotiate midway, gives me coaching, and tells me what to say next when i am in the briefing room.

The `small_talk` agent talks to the investor. The `negotiator` agent talks to me.

Voice/provider split:

- `small_talk` uses ElevenLabs because it needs to sound like me while pitching investors.
- `negotiator` uses MiniMax chat plus MiniMax speech because it is the private midway negotiation coach.
- `simulated_investor` is a local development replacement role, not one of the two agents. it uses its own investor voice provider and must not reuse the founder ElevenLabs clone by default.

## Design Guide - Dark Brutalist

Dark void base, one vivid accent, mono-forward brutalist type, confident technical voice. Accent is a flare, never a fill.

### Principles

- Dark void base.
- One vivid accent.
- Mono-forward brutalist type.
- Confident technical voice.
- Accent is a flare, never a fill.

### Tokens

```css
:root {
  --void: #18000f;
  --ink: #0c0008;
  --accent: #ff2e12;
  --accent-2: #ff5436;
  --signal: #ff1a6b;
  --heat: #ff8a00;
  --text: #f4eef0;
  --text-dim: #b69aa6;
  --muted: #7a5f6c;
  --line: rgba(255, 46, 18, 0.22);
  --line-soft: rgba(244, 238, 240, 0.1);
  --ok: #3ad07a;
}
```

### Color

- Use a 60 void / 30 text and structure / 10 accent balance.
- Keep accent at 10% or less of the surface.
- Use radial gradients only: accent to signal to heat.
- Avoid purple-on-white and flat color washes.
- Text on void must meet AAA contrast.
- Use accent only for 18px+ bold text, icons, and strokes.

### Type

- Use mono-forward typography.
- Mono choices: JetBrains Mono, IBM Plex Mono, Space Mono.
- Display choice: a heavy grotesque.
- Fallback: `ui-monospace`.
- Never use Inter or Arial as the brand typeface.
- Headlines: uppercase, weight 700-800, tracking -0.02 to -0.03em, short, imperative.
- Body: weight 300-400, neutral tracking, line-height around 1.5.
- Labels: uppercase, weight 500, tracking 0.18-0.24em.
- Numbers: oversized accent numeral with a quiet mono label.

### Layout

- Atmosphere, not flatness: faint coordinate grid plus radial accent glow, edge-masked.
- Eyebrow labels: `01 - Section` with an accent rule prefix.
- Panels: 1px `--line-soft`, 6-10px radius, hairline dividers.

### Components

- Primary button: filled `--accent`, dark text, glow and lift on hover, uppercase imperative verb.
- Secondary button: ghost, 1px border, accent on hover.
- Terminal: `--ink` background, accent prompt, dim output, `--ok` success, accent first dot.
- Code: real styled blocks, never screenshots.

### Motion

- Use one orchestrated staggered load.
- Use slow ambient float, 12-16s, on glows.
- Keep motion restrained and CSS-only.

### Voice

- Use proof, not adjectives: "3x faster", not "blazing fast".
- Write engineer-to-engineer.
- Name the stack.
- Explain trade-offs.
- Lead with the number.
- Teach before asking.
- Use one wink per page max.
- Avoid: synergy, leverage, world-class, cutting-edge, revolutionary, seamless, unlock, journey, solutions, disrupt.

### Checklist

- [ ] Dark base, accent at 10% or less.
- [ ] Mono-forward type and tracked uppercase labels.
- [ ] Grid and glow atmosphere.
- [ ] Loud numbers with backed claims.
- [ ] Imperative glowing buttons.
- [ ] One wink max.
- [ ] No banned words.
- [ ] No generic AI look.

## Goal

Build a multi-player voice AI app on Elixir. The product lets the founder call a Telnyx-backed number, press DTMF `3` to mute themself and enter private negotiation briefing, have the small_talk agent continue with the investor in the founder's cloned voice (ElevenLabs), and press DTMF `4` to side-listen while the small_talk agent keeps the conversation warm. The app is Elixir-native and uses Telnyx Call Control/media streaming, MiniMax as the LLM, ElevenLabs for voice cloning, and Moss for retrieval. `Negotiator.Memory` is the primary store for all shared call state — `Memory.write/2` is the single write path, `CallSession.sync/1` flushes after every mutation, and provider jobs read from Memory directly.

## Repo shape

This is a supervised Mix application. The product surface is Telnyx webhooks plus bidirectional media streaming into Elixir processes. Local role replacement happens through guarded HTTP endpoints inside the running voice app, not a separate simulator. Call state, transcript, prediction checkpoints, simulated agents, retrieval, llm boundaries, Telnyx media routing, Moss retrieval, ElevenLabs voice cloning, and MiniMax speech live in `lib/`. Frontend and persistence can come later after the voice path is solid.

Each folder has its own `AGENTS.md` and `MEMORY.md`.

### Architecture, Data-flow action (allowed traffic between services)

`Negotiator.Telephony.TelnyxWebhook` -> `Negotiator.CallSupervisor` -> `Negotiator.CallSession`

`Negotiator.Telephony.MediaSocket` -> `Negotiator.CallSession`

`Negotiator.CallSession` -> `Negotiator.PredictionCoordinator`

`Negotiator.CallSession` -> `Negotiator.Agents.NegotiationAgent`

`Negotiator.CallSession` -> `Negotiator.Agents.SmallTalkAgent`

`Negotiator.CallSession` -> `Negotiator.Agents.SimulatedInvestor`

`Agents` -> `Negotiator.Retrieval` and `Negotiator.LLM`

Adding a new arrow to this diagram is an architecture-level decision — log it in the **primary actor's** `MEMORY.md` before wiring it.

## How to talk

### 1. Kill the filler

Never open responses with filler phrases like "Great question!", "Of course!", "Certainly!", "Absolutely!", "Sure!", or similar warmups.

Start every response with the actual answer. No preamble, no acknowledgment of the question. Just the information.

### 2. Always show options before acting

Before any significant task, show 2-3 ways the work could be approached. Wait for me to choose the direction before producing the full output.

This applies to: rewrites, restructures, design decisions, architecture choices, and any task where multiple reasonable approaches exist.

### 3. Be honest when you don't know

If you are uncertain about any fact, statistic, date, quote, or piece of information, say so explicitly before including it.

"I'm not certain about this" is always better than presenting a guess as a fact. Never fill gaps in your knowledge with plausible-sounding information. When in doubt, say so.

### 4. Match length to what's actually needed

Match response length to task complexity.

- Simple questions get direct, short answers.
- Complex tasks get full, detailed responses.

Never compress or summarize work that requires real depth. Never pad responses with restatements of the question or closing sentences that repeat what you just said.

## How to behave

### 5. Ask before making big changes

Before making any change that significantly alters content I've already created (rewriting sections, removing paragraphs, restructuring the flow, changing tone), stop completely.

Describe exactly what you're about to change and why. Wait for my confirmation before proceeding.

"I think this would be better" is not permission to change it.

### 6. Stay focused on what was asked

Only change what I specifically asked you to change.

Do not rewrite, rephrase, restructure, or "improve" anything I didn't ask about, even if you think it would be better.

If you notice something that could be improved elsewhere, mention it at the end of your response. Do not touch it unless I explicitly ask you to.

### 7. Always tell me what you changed

After completing any editing or writing task, always end with a brief summary:

- **What was changed:** [description]
- **What was left untouched:** [if relevant]
- **What needs my attention:** [anything requiring a decision or review]

Keep it short. This is a status update, not a recap of everything you just did.

### 8. Never take actions on my behalf without asking

Never send, post, publish, share, or schedule anything on my behalf without my explicit confirmation in the current message.

This includes:

- Emails
- Social posts
- Calendar invites
- Document shares
- Any action that affects something outside this conversation

"You mentioned wanting to do this" is not confirmation. I must say yes in the current message.

## Your Context

### 9. Who I am

Distributed system expert who worked on bundlers (Vite, Rspack, Webpack) and database, storage engine.

### 10. What I'm working on

- Toolings for multi-modal data (audio and video)

### 11. My voice and style

- Succinct and precise.

## Hard stops (require explicit yes in the current message)

- Deploying / pushing to any environment.
- DB migrations or schema changes.
- Any irreversible external side effect (emails, API calls, etc).
- Deleting files or overwriting work I haven't asked you to change.

## Memory & continuity

### 12. Maintain MEMORY.md per project folder

- Memory lives **per folder**. No root `MEMORY.md`. Read the `MEMORY.md` for the folder you're in before starting.
- Decision template:

  ```
  ## [YYYY-MM-DD] — [Decision]
  **What was decided:** ...
  **Why:** ...
  **What was rejected:** ...
  ```

- **Cross-cutting decisions** live in the **primary actor's** `MEMORY.md`. The other folder carries a one-line cross-ref.
- Failure log at `ERRORS.md` (root). Update it when an approach takes >2 attempts to work.
- Never contradict a logged decision without flagging it first.
-

### 13. End-of-session summary

When I say "session end", "wrapping up", or "let's stop here", write a session summary to `MEMORY.md`:

```
## Session Summary — [Date]
**Worked on:** [what we focused on]
**Completed:** [what's finished]
**In progress:** [what's started but not done]
**Decisions made:** [key choices from this session]
**Next session:** [what to pick up first and any important context to carry forward]
```

### 14. Maintain ERRORS.md

Maintain a file called `ERRORS.md`. When an approach takes more than 2 attempts to work, log it:

```
## [Task type or description]
**What didn't work:** [approaches that failed and why]
**What worked:** [the approach that finally succeeded]
**Note for next time:** [anything worth remembering for similar tasks]
```

Check `ERRORS.md` before suggesting approaches to tasks similar to logged ones. If a task matches a logged failure, say so and skip to what worked.

### 15. Permanent facts

These facts are always true. Apply them to every session and every task without exception:

a) For application in `/apps` folder

- Users are **very low technical literacy**. UX must be simple, apparent, and direct. If a feature requires a tooltip or a tutorial to be usable, redesign it.
- One restaurant only — **The Seasons**. Not multi-tenant. Don't add tenant/org abstractions unless I ask.
- Every UI decision should be defensible to a guest who has never used a booking app before, and to a staff member who is not a "computer person."

b) For application in `/core` folder:

- This is our core application and users have high technical literacy and good taste.
- UX should still be apparent and direct - not confusing. Most importantly it should be beautiful s

If any task conflicts with one of these, flag it before proceeding. Do not work around a constraint without telling me.

## For Developers

### 16. Stay in scope

Only modify files, functions, and lines of code directly and specifically related to the current task.

Do not refactor, rename, reorganize, reformat, or "improve" anything I did not explicitly ask you to change.

If you notice something worth fixing elsewhere, mention it in a note. Do not touch it. Ever.

### 17. Confirm before anything destructive

Before deleting any file, overwriting existing code, dropping database records, removing dependencies, or making any change that cannot be trivially undone, stop completely. List exactly what will be affected. Ask for explicit confirmation. Only proceed after I say yes in the current message.

### 18. Hard stops

The following actions require explicit in-session confirmation before executing, no exceptions:

- Deploying or pushing to any environment (staging, production, etc.)
- Running migrations or schema changes on any database
- Sending any email, message, or external API call
- Executing any command with irreversible external side effects

"You mentioned this earlier" is not confirmation. I must say yes in the current message.

### 19. Tech stack

Always use these. Never suggest alternatives unless I ask:

- Refer to `AGENTS.md` in project folder - if you are working on that folder read those instead

### 20. Always show exactly what changed

After completing any coding task, always end with:

- **Files changed:** [list every file touched]
- **What was modified:** [one line per file]
- **Files intentionally not touched:** [if relevant]
- **Follow-up needed:** [anything requiring my attention or a decision]

Keep it short. This is a status update, not a recap.

### 21. Shared constants live in a constants module

When a literal value (domain enum, magic number with business meaning, regex, etc.) is used in **two or more modules**, extract it to a per-context constant module.

### 22. Single source of truth

Every concept lives in exactly one place. The moment the same function, regex, validation, formatter, mapping, or behaviour appears in **two** modules, stop and extract it to a shared module before adding a third copy. This applies to:

- Helper functions should live in their own `utils` folder
- When attempting to write a helper function, check if there is something existing first to prevent duplicates and reduce maintenance effort
- HARD STOP ON DUPLICATED HELPER FUNCTIONS
- DAL functions should live in their own `actions` folder
- Regex patterns
- Mappings (status → label, role → CSS class)
- Validation rules
- Tool / behaviour implementations that share a contract

The threshold is two, not three. Three copies is already three places to fix the same bug. If a similar pattern exists somewhere else, find it before writing the second copy — search the codebase first, extract second, then implement.

Naming clash check: when extracting, never reuse a name that already exists in the same context (e.g. don't name a new module `Registry` when `CallRegistry` already exists to avoid shadowing stdlib `Registry`). Centralising should reduce ambiguity, not add it.

### 23. The Karpathy 4

1. **Ask, don't assume.** If something is unclear or underspecified, ask before writing a single line. Never make silent assumptions about intent, architecture, or requirements.

2. **Simplest solution first.** Always implement the simplest thing that could work. Do not add abstractions, layers, or flexibility that weren't explicitly requested.

3. **Don't touch unrelated code.** If a file or function is not directly part of the current task, do not modify it, even if you think it could be improved.

4. **Flag uncertainty explicitly.** If you are not confident about an approach, a library's behavior, or a technical detail, say so before proceeding. Confidence without certainty causes more damage than admitting a gap.

When in doubt about audience for the file you're editing, read the folder's `AGENTS.md`.
