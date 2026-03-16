import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { serve } from "@hono/node-server";
import { createNodeWebSocket } from "@hono/node-ws";
import "dotenv/config";

import authRoutes from "./routes/auth";
import territoriesRoutes from "./routes/territories";
import rankingsRoutes from "./routes/rankings";
import { addClient, getConnectedCount } from "./services/websocket";

const app = new Hono();

// WebSocket setup
const { injectWebSocket, upgradeWebSocket } = createNodeWebSocket({ app });

// Middleware
app.use("*", cors());
app.use("*", logger());

// Health check
app.get("/", (c) =>
  c.json({
    name: "Turf Wars API",
    version: "1.0.0",
    connections: getConnectedCount(),
  })
);

// API routes
app.route("/auth", authRoutes);
app.route("/territories", territoriesRoutes);
app.route("/rankings", rankingsRoutes);

// WebSocket endpoint for real-time updates
app.get(
  "/ws",
  upgradeWebSocket((c) => ({
    onOpen(evt, ws) {
      const remove = addClient(ws as any);
      (ws as any).__removeClient = remove;
      console.log("WebSocket client connected");
    },
    onMessage(evt, ws) {
      // Handle incoming messages (e.g., subscribe to specific regions)
      try {
        const data = JSON.parse(evt.data as string);
        console.log("WS message:", data);
      } catch {
        // ignore invalid messages
      }
    },
    onClose(evt, ws) {
      (ws as any).__removeClient?.();
      console.log("WebSocket client disconnected");
    },
  }))
);

// Start server
const port = parseInt(process.env.PORT || "3005");

const server = serve({ fetch: app.fetch, port }, (info) => {
  console.log(`🏔️ Turf Wars API running on http://localhost:${info.port}`);
});

injectWebSocket(server);
