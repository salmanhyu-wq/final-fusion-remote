const roomPattern = /^[0-9a-f]{64}$/;
const publicKeyPattern = /^04[0-9a-f]{128}$/;
const viewerRoute = /^\/v2\/(receiver|enroll)\/([0-9a-f]{64})$/;
const hostRoutes = new Map([
  ["/v2/sender", "sender"], ["/v2/enrollment-sender", "enrollment-sender"],
  ["/v2/authorize", "authorize"], ["/v2/release", "release"],
]);

const bytes = (hex) => Uint8Array.from(hex.match(/../g), (pair) => parseInt(pair, 16));
const hex = (data) => Array.from(new Uint8Array(data), (byte) => byte.toString(16).padStart(2, "0")).join("");
const empty = (status) => new Response(null, { status });
const upgrade = (request) => request.headers.get("upgrade")?.toLowerCase() === "websocket";

async function senderRoom(request) {
  const key = request.headers.get("authorization")?.replace(/^Bearer /, "");
  if (!key || !request.headers.get("authorization").startsWith("Bearer ") || !roomPattern.test(key)) return null;
  return hex(await crypto.subtle.digest("SHA-256", bytes(key)));
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === "/health" && request.method === "GET") {
      return new Response("Final Fusion relay v2", { status: roomPattern.test(env.STUDIO_ROOM ?? "") ? 200 : 503 });
    }
    const host = hostRoutes.get(path);
    const viewer = viewerRoute.exec(path);
    if (!host && !viewer) return empty(404);
    const room = host ? await senderRoom(request) : viewer[2];
    if (!room || room !== env.STUDIO_ROOM) return empty(404);
    const role = host || viewer[1];
    const isControl = role === "authorize" || role === "release";
    const probe = !host && role === "receiver" && request.method === "HEAD";
    if (request.method !== (isControl ? "POST" : probe ? "HEAD" : "GET")) return empty(405);
    if (!isControl && !probe && !upgrade(request)) return empty(426);
    const headers = new Headers();
    if (upgrade(request)) headers.set("upgrade", "websocket");
    if (!host) headers.set("authorization", request.headers.get("authorization") ?? "");
    const stub = env.ROOM.get(env.ROOM.idFromName(room));
    let body = null;
    if (role === "authorize") {
      body = await request.text();
      if (body.length > 10_000) return empty(413);
    }
    return stub.fetch(new Request("https://studio.internal/" + role + "/" + room, { method: request.method, headers, body }));
  },
};

export class StudioRoom {
  constructor(ctx) {
    this.ctx = ctx;
  }

  sockets(role) {
    return this.ctx.getWebSockets("ff-v2:" + role).filter((socket) => socket.readyState === WebSocket.OPEN);
  }

  async authorized(request, room) {
    const auth = /^FF2 (04[0-9a-f]{128}) ([0-9]{1,12}) ([0-9a-f]{32}) ([0-9a-f]{128})$/.exec(
      request.headers.get("authorization") ?? "",
    );
    if (!auth) return false;
    const [, publicKey, stamp, nonce, signature] = auth;
    const seconds = Number(stamp);
    if (Math.abs(Date.now() / 1000 - seconds) > 30) return false;
    const registry = await this.ctx.storage.get("v2-devices");
    if (!registry?.devices.includes(publicKey)) return false;
    try {
      const key = await crypto.subtle.importKey("raw", bytes(publicKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
      const message = new TextEncoder().encode(
        ["final-fusion-relay-v2", request.method, room, stamp, nonce].join(":"),
      );
      if (!await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, bytes(signature), message)) return false;
    } catch {
      return false;
    }
    return { publicKey, nonce, seconds };
  }

  async claimProof({ publicKey, nonce, seconds }) {
    // Store recent nonces per approved key so a retry in the same second can
    // use a fresh proof while a copied request stays spent after hibernation.
    return this.ctx.storage.transaction(async (transaction) => {
      const current = await transaction.get("v2-devices");
      if (!current?.devices.includes(publicKey)) return false;
      const key = "v2-proof:" + publicKey;
      const now = Date.now() / 1000;
      if (Math.abs(now - seconds) > 30) return false;
      const recent = (await transaction.get(key) ?? []).filter(([, stamp]) => now - stamp <= 30);
      if (recent.length >= 32 || recent.some(([used]) => used === nonce)) return false;
      await transaction.put(key, [...recent, [nonce, seconds]]);
      return true;
    });
  }

  async fetch(request) {
    const [, role, room] = new URL(request.url).pathname.split("/");
    if (role === "authorize") {
      let body;
      try { body = await request.json(); } catch { return empty(400); }
      if (!roomPattern.test(body?.enrollment ?? "") || !Array.isArray(body.devices) || body.devices.length > 64 ||
          body.devices.some((key) => typeof key !== "string" || !publicKeyPattern.test(key))) return empty(400);
      await this.ctx.storage.transaction(async (transaction) => {
        const old = await transaction.get("v2-devices");
        const devices = [...new Set(body.devices)];
        const removed = old?.devices.filter((key) => !devices.includes(key)) ?? [];
        if (removed.length) await transaction.delete(removed.map((key) => "v2-proof:" + key));
        await transaction.put("v2-devices", { enrollment: body.enrollment, devices });
      });
      return empty(204);
    }
    if (role === "release") {
      const sender = this.sockets("sender")[0];
      if (sender?.deserializeAttachment()?.session) return empty(409);
      if (sender) this.close(sender, 1000, "sender handoff");
      return empty(204);
    }
    if (!["sender", "receiver", "enroll", "enrollment-sender"].includes(role)) return empty(404);
    let proof;
    if (role === "receiver") {
      proof = await this.authorized(request, room);
      if (!proof) return empty(403);
      if (request.method === "HEAD") return empty(204);
    }
    if (role === "enroll") {
      const registry = await this.ctx.storage.get("v2-devices");
      if (!registry || request.headers.get("authorization") !== "Bearer " + registry.enrollment) return empty(403);
    }

    const sender = role === "sender" || role === "enrollment-sender";
    const enrollment = role === "enrollment-sender" || role === "enroll";
    const hostRole = enrollment ? "enrollment-sender" : "sender";
    const viewerRole = enrollment ? "enroll" : "receiver";
    const busy = (host) => this.sockets(viewerRole).length > 0 || host.deserializeAttachment()?.session;
    let host = this.sockets(hostRole)[0];
    if (sender && host) return empty(409);
    if (!sender) {
      if (!host) return empty(503);
      if (busy(host)) return empty(409);
      if (proof && !await this.claimProof(proof)) return empty(403);
      // The availability checks must be repeated after the storage transaction.
      host = this.sockets(hostRole)[0];
      if (!host) return empty(503);
      if (busy(host)) return empty(409);
    }

    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, ["ff-v2:" + role]);
    if (sender) {
      server.serializeAttachment({ role, other: viewerRole, session: null });
    } else {
      const session = crypto.randomUUID();
      server.serializeAttachment({ role, other: hostRole, session });
      host.serializeAttachment({ role: hostRole, other: viewerRole, session });
      try { host.send("paired"); } catch {
        this.close(server, 1011, "sender unavailable");
        this.close(host, 1011, "sender unavailable");
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  other(attachment) {
    if (!attachment?.session || !attachment.other) return undefined;
    return this.sockets(attachment.other).find((socket) => socket.deserializeAttachment()?.session === attachment.session);
  }

  webSocketMessage(socket, data) {
    const peer = this.other(socket.deserializeAttachment());
    if (!(data instanceof ArrayBuffer) || !data.byteLength || data.byteLength > 65536 || !peer) {
      this.close(socket, 1008, "invalid stream");
      if (peer) this.close(peer, 1008, "invalid stream");
      return;
    }
    try { peer.send(data); } catch {
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
    try { socket.close(code, reason); } catch { /* Already closed. */ }
  }
}
