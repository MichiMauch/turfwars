import type { ServerWebSocket } from "hono/ws";

interface ConnectedClient {
  ws: ServerWebSocket;
  userId?: string;
}

const clients = new Set<ConnectedClient>();

export function addClient(ws: ServerWebSocket, userId?: string) {
  const client: ConnectedClient = { ws, userId };
  clients.add(client);
  return () => clients.delete(client);
}

export function broadcastTerritoryUpdate(data: unknown) {
  const message = JSON.stringify(data);
  for (const client of clients) {
    try {
      client.ws.send(message);
    } catch {
      clients.delete(client);
    }
  }
}

export function getConnectedCount() {
  return clients.size;
}
