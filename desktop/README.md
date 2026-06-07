# Negotiator Desktop

Electron observer overlay for the local negotiation assistant.

This first cut is display-only. It shows a mock version of the state the Elixir call engine owns: mode, room topology, transcript, candidate lines, private coaching, and event log. It does not own call handling, DTMF, agent decisions, or transcript mutation.

## Run

```sh
npm install
npm run dev
```

Global shortcut:

```text
cmd/ctrl + shift + space
```

The shortcut hides or shows the overlay.

## Boundary

The desktop app is a local observer surface. The source of truth remains `Negotiator.CallSession` when the Elixir bridge is added later.
