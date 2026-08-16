import type { NetworkMonitor } from "./types.ts";

/** LTE/5G (or any IP) reconnect: browser `online`/`offline`. Tablet shells can wrap this. */
export function createLteReconnectMonitor(): NetworkMonitor {
  return createBrowserNetworkMonitor();
}

export function createBrowserNetworkMonitor(): NetworkMonitor {
  return {
    isOnline() {
      if (typeof navigator === "undefined") return true;
      return navigator.onLine;
    },
    subscribe(listener) {
      if (typeof window === "undefined") return () => undefined;
      const on = () => listener(true);
      const off = () => listener(false);
      window.addEventListener("online", on);
      window.addEventListener("offline", off);
      return () => {
        window.removeEventListener("online", on);
        window.removeEventListener("offline", off);
      };
    },
  };
}
