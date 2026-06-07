import { useEffect, useMemo, useState, type ReactNode } from "react";
import {
   Activity,
   AudioWaveform,
   BookOpen,
   ChevronLeft,
   CircleDot,
   Eye,
   Minus,
   PanelTopClose,
   Radio,
   ShieldCheck,
   Sparkles,
} from "lucide-react";
import type {
   InvestorCallRecord,
   LiveCallFrame,
   Room,
   RoomStatus,
   TranscriptTurn,
} from "./callTypes";

type AppTab = "records" | "live";

type BackendCall = {
   call_id?: string;
   mode?: string;
   signal?: string;
   candidates?: string[];
   transcript?: TranscriptTurn[];
   briefing?: string | null;
   prediction_checkpoint?: number;
   investor_name?: string | null;
   investor_firm?: string | null;
   media_socket_participants?: string[];
   latest_audio_participant?: string | null;
   response_lifecycle?: {
      role?: string | null;
      status?: string | null;
   };
   last_events?: Array<
      | string
      | { type?: string; sequence?: number; payload?: Record<string, unknown> }
   >;
};

const roleLabels: Record<TranscriptTurn["role"], string> = {
   founder: "founder",
   investor: "investor",
   negotiation_agent: "coach",
   small_talk_agent: "small talk",
};

const statusLabels: Record<RoomStatus, string> = {
   live: "live",
   private: "private",
   muted: "muted",
   standby: "standby",
};

function App() {
   const [activeTab, setActiveTab] = useState<AppTab>("records");
   const [selectedRecordId, setSelectedRecordId] = useState<string | null>(
      null,
   );
   const [backendCall, setBackendCall] = useState<BackendCall | null>(null);
   const [records, setRecords] = useState<InvestorCallRecord[]>([]);

   useEffect(() => {
      let cancelled = false;
      let ws: WebSocket | null = null;
      let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
      const apiBase =
         import.meta.env.VITE_NEGOTIATOR_API_URL || "http://127.0.0.1:4000";
      const wsUrl = apiBase.replace(/^http/, "ws") + "/ws/calls";

      function connect() {
         if (cancelled) return;

         ws = new WebSocket(wsUrl);

         ws.onopen = () => {
            console.log("[ws] connected to", wsUrl);
         };

         ws.onmessage = (event) => {
            if (cancelled) return;
            try {
               const payload = JSON.parse(event.data) as {
                  type?: string;
                  calls?: BackendCall[];
               };
               if (payload.type === "calls") {
                  setBackendCall(payload.calls?.[0] || null);
               }
            } catch {
               // ignore malformed messages
            }
         };

         ws.onclose = () => {
            if (cancelled) return;
            console.log("[ws] disconnected, reconnecting in 2s");
            setBackendCall(null);
            reconnectTimer = setTimeout(connect, 2_000);
         };

         ws.onerror = () => {
            ws?.close();
         };
      }

      connect();

      return () => {
         cancelled = true;
         if (reconnectTimer) clearTimeout(reconnectTimer);
         ws?.close();
      };
   }, []);

   useEffect(() => {
      let cancelled = false;
      const apiBase =
         import.meta.env.VITE_NEGOTIATOR_API_URL || "http://127.0.0.1:4000";

      async function fetchRecords() {
         try {
            const res = await fetch(`${apiBase}/records`);
            if (!res.ok) return;
            const data = (await res.json()) as { records?: InvestorCallRecord[] };
            if (!cancelled && data.records) {
               setRecords(data.records);
            }
         } catch {
            // backend not reachable
         }
      }

      fetchRecords();
      const timer = window.setInterval(fetchRecords, 15_000);

      return () => {
         cancelled = true;
         window.clearInterval(timer);
      };
   }, []);

   const liveFrame = useMemo(
      () => liveFrameFromBackend(backendCall),
      [backendCall],
   );
   const selectedRecord =
      records.find((record) => record.id === selectedRecordId) || null;

   return (
      <main className="overlay-shell">
         <TitleBar
            activeTab={activeTab}
            onTabChange={setActiveTab}
            signal={liveFrame?.signal || "offline"}
         />

         {activeTab === "records" ? (
            <RecordsTab
               liveFrame={liveFrame}
               onOpenLive={() => setActiveTab("live")}
               onSelectRecord={setSelectedRecordId}
               records={records}
               selectedRecord={selectedRecord}
            />
         ) : (
            <LiveCallTab frame={liveFrame} />
         )}
      </main>
   );
}

function TitleBar({
   activeTab,
   onTabChange,
   signal,
}: {
   activeTab: AppTab;
   onTabChange: (tab: AppTab) => void;
   signal: string;
}) {
   return (
      <header className="titlebar">
         <div className="drag-region">
            <span className="app-mark">N</span>
            <span className="title-copy">negotiator desktop</span>
            <nav className="tab-bar" aria-label="main views">
               <TabButton
                  active={activeTab === "records"}
                  onClick={() => onTabChange("records")}
               >
                  investor records
               </TabButton>
               <TabButton
                  active={activeTab === "live"}
                  onClick={() => onTabChange("live")}
               >
                  live call
               </TabButton>
            </nav>
            <span className="signal-pill">
               <Radio size={13} />
               {signal}
            </span>
         </div>

         <div className="window-actions">
            <button
               aria-label="minimize overlay"
               onClick={() => window.negotiatorOverlay?.minimize()}
               type="button"
            >
               <Minus size={15} />
            </button>
            <button
               aria-label="hide overlay"
               onClick={() => window.negotiatorOverlay?.toggleVisibility()}
               type="button"
            >
               <Eye size={15} />
            </button>
            <button
               aria-label="close overlay"
               onClick={() => window.negotiatorOverlay?.close()}
               type="button"
            >
               <PanelTopClose size={15} />
            </button>
         </div>
      </header>
   );
}

function TabButton({
   active,
   children,
   onClick,
}: {
   active: boolean;
   children: ReactNode;
   onClick: () => void;
}) {
   return (
      <button
         className={active ? "tab-button tab-button-active" : "tab-button"}
         onClick={onClick}
         type="button"
      >
         {children}
      </button>
   );
}

function Metric({ value, label }: { value: string; label: string }) {
   return (
      <div className="metric">
         <strong>{value}</strong>
         <span>{label}</span>
      </div>
   );
}

function RecordsTab({
   liveFrame,
   onOpenLive,
   onSelectRecord,
   records,
   selectedRecord,
}: {
   liveFrame: LiveCallFrame | null;
   onOpenLive: () => void;
   onSelectRecord: (recordId: string | null) => void;
   records: InvestorCallRecord[];
   selectedRecord: InvestorCallRecord | null;
}) {
   if (selectedRecord) {
      return (
         <RecordDetail
            record={selectedRecord}
            onBack={() => onSelectRecord(null)}
         />
      );
   }

   return (
      <section className="records-view">
         <section className="records-main">
            <div className="section-heading">
               <p className="eyebrow">01 - investor records</p>
               <h1>CALL LEDGER</h1>
            </div>

            {liveFrame ? (
               <LiveNowCard frame={liveFrame} onOpenLive={onOpenLive} />
            ) : null}

            <div className="record-list" aria-label="previous investor calls">
               <div className="list-title">
                  <BookOpen size={16} />
                  <span>previous calls</span>
               </div>

               {records.length > 0 ? (
                  records.map((record) => (
                     <button
                        className="record-row"
                        key={record.id}
                        onClick={() => onSelectRecord(record.id)}
                        type="button"
                     >
                        <span className="record-name">
                           {record.investorName}
                        </span>
                        <span>{record.investorFirm}</span>
                        <span>{record.dateLabel}</span>
                        <span>{record.duration}</span>
                        <strong>{record.status}</strong>
                        <small>{record.lastNote}</small>
                     </button>
                  ))
               ) : (
                  <EmptyState
                     title="no saved calls"
                     body="call records will appear here."
                  />
               )}
            </div>
         </section>

         <aside className="records-side panel">
            <PanelHeader
               icon={<CircleDot size={16} />}
               label="02 - first page"
               title="live first"
            />
            <p>
               Active calls stay pinned above the historical ledger. Click the
               live card to enter the full call cockpit.
            </p>
            <div className="side-stat">
               <strong>{liveFrame?.mode || "idle"}</strong>
               <span>current mode</span>
            </div>
            <div className="side-stat">
               <strong>{liveFrame?.activeRole || "none"}</strong>
               <span>active voice</span>
            </div>
         </aside>
      </section>
   );
}

function LiveNowCard({
   frame,
   onOpenLive,
}: {
   frame: LiveCallFrame;
   onOpenLive: () => void;
}) {
   const latestTurn = frame.transcript.at(-1);

   return (
      <article className="live-now-card">
         <div className="live-now-topline">
            <span className="live-badge">live now</span>
            <span>{frame.callId}</span>
         </div>

         <div className="live-now-grid">
            <div>
               <h2>{frame.investorName}</h2>
               <p>{frame.investorFirm}</p>
            </div>
            <Metric value={frame.mode} label="mode" />
            <Metric value={frame.activeRole} label="active voice" />
         </div>

         {latestTurn ? (
            <p className="latest-line">
               <span>{roleLabels[latestTurn.role]}</span>
               {latestTurn.text}
            </p>
         ) : null}

         <button className="primary-action" onClick={onOpenLive} type="button">
            open live call
         </button>
      </article>
   );
}

function RecordDetail({
   record,
   onBack,
}: {
   record: InvestorCallRecord;
   onBack: () => void;
}) {
   return (
      <section className="detail-view">
         <button className="back-button" onClick={onBack} type="button">
            <ChevronLeft size={16} />
            back
         </button>

         <div className="detail-grid">
            <section className="panel detail-summary">
               <div className="detail-kicker">
                  {record.dateLabel} / {record.duration} / {record.status}
               </div>
               <h1>{record.investorName}</h1>
               <h2>{record.investorFirm}</h2>
               <p>{record.summary}</p>
            </section>

            <section className="panel detail-moments">
               <PanelHeader
                  icon={<Sparkles size={16} />}
                  label="02 - moments"
                  title="key turns"
               />
               <div className="moment-list">
                  {record.keyMoments.map((moment) => (
                     <p key={moment}>{moment}</p>
                  ))}
               </div>
            </section>

            <TranscriptPanel turns={record.transcript} />
            <EventPanel events={record.events} />
         </div>
      </section>
   );
}

function LiveCallTab({ frame }: { frame: LiveCallFrame | null }) {
   const eventWindow = useMemo(
      () => frame?.events.slice(-5) || [],
      [frame?.events],
   );

   if (!frame) {
      return (
         <section className="empty-live-view">
            <div className="section-heading">
               <p className="eyebrow">01 - live call</p>
               <h1>NO ACTIVE CALL</h1>
            </div>
            <EmptyState title="waiting for /calls" body="start a call to see live data here" />
         </section>
      );
   }

   return (
      <>
         <section className="hero-strip" aria-label="call summary">
            <div>
               <p className="eyebrow">01 - live call</p>
               <h1>NEGOTIATION ROOM</h1>
            </div>

            <div className="mode-cluster">
               <Metric value={frame.mode} label="mode" />
               <Metric
                  value={`#${frame.wordCheckpoint}`}
                  label="3 word checkpoint"
               />
               <Metric value={frame.activeRole} label="active voice" />
            </div>
         </section>

         <section className="console-grid">
            <RoomPanel frame={frame} />
            <TranscriptPanel turns={frame.transcript} />
            <CoachPanel frame={frame} />
            <EventPanel events={eventWindow} />
         </section>
      </>
   );
}

function RoomPanel({ frame }: { frame: LiveCallFrame }) {
   return (
      <section className="panel room-panel" aria-label="rooms">
         <PanelHeader
            icon={<AudioWaveform size={16} />}
            label="02 - rooms"
            title="live topology"
         />
         <div className="room-list">
            {frame.rooms.map((room) => (
               <article className="room-row" key={room.name}>
                  <span className={`status-dot status-${room.status}`} />
                  <div>
                     <h3>{room.name}</h3>
                     <p>{room.line}</p>
                  </div>
                  <span className="status-label">
                     {statusLabels[room.status]}
                  </span>
               </article>
            ))}
         </div>
      </section>
   );
}

function TranscriptPanel({ turns }: { turns: TranscriptTurn[] }) {
   return (
      <section className="panel transcript-panel" aria-label="transcript">
         <PanelHeader
            icon={<Activity size={16} />}
            label="03 - transcript"
            title="shared memory"
         />
         <div className="transcript-stream">
            {turns.map((turn, index) => (
               <article className="turn" key={`${turn.role}-${index}`}>
                  <div className="turn-meta">
                     <span>{roleLabels[turn.role]}</span>
                     <span>{turn.room}</span>
                  </div>
                  <p>{turn.text}</p>
               </article>
            ))}
         </div>
      </section>
   );
}

function CoachPanel({ frame }: { frame: LiveCallFrame }) {
   return (
      <section
         className="panel coach-panel"
         aria-label="coach and candidate lines"
      >
         <PanelHeader
            icon={<ShieldCheck size={16} />}
            label="04 - coach"
            title="private brief"
         />
         <p className="briefing-copy">{frame.briefing}</p>

         <div className="candidate-list">
            {frame.candidates.map((candidate, index) => (
               <article className="candidate" key={candidate}>
                  <span>{String.fromCharCode(65 + index)}</span>
                  <p>{candidate}</p>
               </article>
            ))}
         </div>
      </section>
   );
}

function EventPanel({ events }: { events: string[] }) {
   return (
      <section className="panel event-panel" aria-label="event log">
         <PanelHeader
            icon={<Sparkles size={16} />}
            label="05 - event log"
            title="state transitions"
         />
         <div className="terminal">
            {events.map((event, index) => (
               <p key={`${event}-${index}`}>
                  <span>{index === 0 ? ">" : "$"}</span>
                  {event}
               </p>
            ))}
         </div>
      </section>
   );
}

function PanelHeader({
   icon,
   label,
   title,
}: {
   icon: ReactNode;
   label: string;
   title: string;
}) {
   return (
      <div className="panel-header">
         <p className="eyebrow">
            {icon}
            {label}
         </p>
         <h2>{title}</h2>
      </div>
   );
}

function EmptyState({ title, body }: { title: string; body: string }) {
   return (
      <div className="empty-state">
         <strong>{title}</strong>
         <p>{body}</p>
      </div>
   );
}

function liveFrameFromBackend(call: BackendCall | null): LiveCallFrame | null {
   if (!call?.call_id) {
      return null;
   }

   const mode = normalizeMode(call.mode);
   const transcript = Array.isArray(call.transcript) ? call.transcript : [];
   const events = normalizeEvents(call.last_events);
   const activeRole =
      call.response_lifecycle?.role || call.latest_audio_participant || "none";

   return {
      callId: call.call_id,
      investorName: call.investor_name || "unknown investor",
      investorFirm: call.investor_firm || "unknown firm",
      mode,
      signal: "api live",
      activeRole,
      rooms: roomsForMode(mode, call.media_socket_participants || []),
      transcript,
      candidates: call.candidates || [],
      briefing:
         call.briefing ||
         "private briefing will appear when the negotiator produces advice.",
      wordCheckpoint: call.prediction_checkpoint || 0,
      events,
   };
}

function normalizeMode(mode: string | undefined): LiveCallFrame["mode"] {
   if (mode === "briefing" || mode === "agent_takeover") {
      return mode;
   }

   return "normal";
}

function normalizeEvents(events: BackendCall["last_events"]) {
   if (!events?.length) {
      return [];
   }

   return events.map((event) => {
      if (typeof event === "string") {
         return event;
      }

      const prefix =
         typeof event.sequence === "number" ? `${event.sequence}: ` : "";
      return `${prefix}${event.type || "call_event"}`;
   });
}

function roomsForMode(
   mode: LiveCallFrame["mode"],
   participants: string[],
): Room[] {
   const participantLabel = participants.length
      ? participants.join(", ")
      : "media socket waiting";

   if (mode === "briefing") {
      return [
         {
            name: "main call",
            status: "muted",
            line: `founder muted / ${participantLabel}`,
         },
         {
            name: "briefing",
            status: "private",
            line: "negotiation agent coaching founder",
         },
         {
            name: "small talk",
            status: "live",
            line: "agent keeps investor engaged",
         },
      ];
   }

   if (mode === "agent_takeover") {
      return [
         {
            name: "main call",
            status: "muted",
            line: `founder side listening / ${participantLabel}`,
         },
         {
            name: "briefing",
            status: "private",
            line: "coach watches the full transcript",
         },
         {
            name: "small talk",
            status: "live",
            line: "style-matched agent continues",
         },
      ];
   }

   return [
      {
         name: "main call",
         status: "live",
         line: `founder and investor connected / ${participantLabel}`,
      },
      { name: "briefing", status: "standby", line: "private coach idle" },
      { name: "small talk", status: "standby", line: "agent muted" },
   ];
}

export default App;
