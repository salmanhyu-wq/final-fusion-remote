const roomPattern = /^[0-9a-f]{64}$/;
const receiverPath = /^\/v1\/receiver\/([0-9a-f]{64})$/;
const senderPath = "/v1/sender";

async function senderRoom(request) {
  const bearer = request.headers.get("authorization") ?? "";
  if (!bearer.startsWith("Bearer ") || !roomPattern.test(bearer.slice(7))) return null;
  const secret = Uint8Array.from(bearer.slice(7).match(/../g), (pair) => parseInt(pair, 16));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", secret));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export default {
  async fetch(request, env) {
    if (request.method !== "GET") return new Response(null, { status: 405 });
    const path = new URL(request.url).pathname;
    if (path === "/health") {
      return new Response("Studio Remote relay v1", { status: roomPattern.test(env.STUDIO_ROOM ?? "") ? 200 : 503 });
    }
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response(null, { status: 426 });
    }
    const sender = path === senderPath;
    const room = sender ? await senderRoom(request) : receiverPath.exec(path)?.[1];
    if (!room || room !== env.STUDIO_ROOM) return new Response(null, { status: 404 });

    const stub = env.ROOM.get(env.ROOM.idFromName(room));
    return stub.fetch(new Request(sender ? "https://studio.internal/sender" : "https://studio.internal/receiver", {
      headers: { Upgrade: "websocket" },
    }));
  },
};

export class StudioRoom {
  constructor(ctx) {
    this.ctx = ctx;
  }

  sockets(role) {
    return this.ctx.getWebSockets(role).filter((socket) => socket.readyState === WebSocket.OPEN);
  }

  fetch(request) {
    const sender = new URL(request.url).pathname === "/sender";
    const host = this.sockets("sender")[0];
    const viewer = this.sockets("receiver")[0];
    if (sender && host) return new Response(null, { status: 409 });
    if (!sender && !host) return new Response(null, { status: 503 });
    if (!sender && viewer) return new Response(null, { status: 409 });

    const [client, server] = Object.values(new WebSocketPair());
    const role = sender ? "sender" : "receiver";
    this.ctx.acceptWebSocket(server, [role]);

    if (sender) {
      server.serializeAttachment({ role, session: null });
    } else {
      const session = crypto.randomUUID();
      server.serializeAttachment({ role, session });
      host.serializeAttachment({ role: "sender", session });
      try {
        host.send("paired");
      } catch {
        this.close(server, 1011, "sender unavailable");
        this.close(host, 1011, "sender unavailable");
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  other(attachment) {
    if (!attachment?.session) return undefined;
    const role = attachment.role === "sender" ? "receiver" : "sender";
    return this.sockets(role).find((socket) => socket.deserializeAttachment()?.session === attachment.session);
  }

  webSocketMessage(socket, data) {
    const peer = this.other(socket.deserializeAttachment());
    if (!(data instanceof ArrayBuffer) || !data.byteLength || data.byteLength > 65536 || !peer) {
      this.close(socket, 1008, "invalid stream");
      if (peer) this.close(peer, 1008, "invalid stream");
      return;
    }
    try {
      peer.send(data);
    } catch {
      this.close(socket, 1011, "peer unavailable");
      this.close(peer, 1011, "peer unavailable");
    }
  }

  webSocketClose(socket) {
    const peer = this.other(socket.deserializeAttachment());
    if (peer) this.close(peer, 1000, "session ended");
  }

  webSocketError(socket) {
    const peer = this.other(socket.deserializeAttachment());
    this.close(socket, 1011, "connection error");
    if (peer) this.close(peer, 1011, "connection error");
  }

  close(socket, code, reason) {
    try {
      socket.close(code, reason);
    } catch {
      // A peer may already have closed the connection.
    }
  }
}
