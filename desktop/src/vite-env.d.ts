/// <reference types="vite/client" />

interface NegotiatorOverlayApi {
  minimize: () => Promise<void>;
  close: () => Promise<void>;
  toggleVisibility: () => Promise<void>;
}

interface Window {
  negotiatorOverlay?: NegotiatorOverlayApi;
}
