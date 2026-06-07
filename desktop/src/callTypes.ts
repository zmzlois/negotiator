export type RoomStatus = "live" | "private" | "muted" | "standby";

export type Room = {
  name: string;
  status: RoomStatus;
  line: string;
};

export type TranscriptTurn = {
  role: "founder" | "investor" | "negotiation_agent" | "small_talk_agent";
  text: string;
  room: "main" | "briefing" | "small_talk";
};

export type LiveCallFrame = {
  callId: string;
  investorName: string;
  investorFirm: string;
  mode: "normal" | "briefing" | "agent_takeover";
  signal: string;
  wordCheckpoint: number;
  activeRole: string;
  rooms: Room[];
  transcript: TranscriptTurn[];
  briefing: string;
  candidates: string[];
  events: string[];
};

export type InvestorCallRecord = {
  id: string;
  investorName: string;
  investorFirm: string;
  dateLabel: string;
  duration: string;
  status: "completed" | "briefing used" | "agent takeover";
  summary: string;
  lastNote: string;
  keyMoments: string[];
  transcript: TranscriptTurn[];
  events: string[];
};
