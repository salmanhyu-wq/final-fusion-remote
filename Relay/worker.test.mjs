import assert from "node:assert/strict";
import { test } from "node:test";
import { webcrypto } from "node:crypto";
import worker, { StudioRoom } from "./worker.js";

globalThis.crypto ??= webcrypto;
globalThis.WebSocket = { OPEN: 1 };
const sockets = [];
globalThis.WebSocketPair = class {
  constructor() {
    return [null, {
      readyState: 1,
      sent: [],
      serializeAttachment(value) { this.attachment = value; },
      deserializeAttachment() { return this.attachment; },
      send(message) { this.sent.push(message); },
      close() { this.readyState = 3; },
    }];
  }
};
const FetchResponse = globalThis.Response;
globalThis.Response = class extends FetchResponse {
  constructor(body, init) {
    super(body, init?.status === 101 ? { ...init, status: 200 } : init);
    this.workerStatus = init?.status;
  }
};
const status = (response) => response.workerStatus ?? response.status;
const hex = (data) => Buffer.from(data).toString("hex");

test("only approved proofs can reserve the desktop slot; enrollment uses its own slot", async () => {
  const secret = Buffer.alloc(32, 19);
  const room = hex(await crypto.subtle.digest("SHA-256", secret));
  const sender = "Bearer " + hex(secret);
  const enrollment = "12".repeat(32);
  const key = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const publicKey = hex(await crypto.subtle.exportKey("raw", key.publicKey));
  const values = new Map();
  const storage = {
    async get(name) { return structuredClone(values.get(name)); },
    async put(name, value) { values.set(name, structuredClone(value)); },
    async delete(names) { names.forEach((name) => values.delete(name)); },
    async transaction(fn) { return fn(storage); },
  };
  const instance = new StudioRoom({
    storage,
    getWebSockets(tag) { return sockets.filter((entry) => "ff-v2:" + entry.role === tag).map((entry) => entry.socket); },
    acceptWebSocket(socket, [tag]) { sockets.push({ socket, role: tag.replace(/^ff-v2:/, "") }); },
  });
  const env = { STUDIO_ROOM: room, ROOM: { idFromName: (id) => id, get: () => instance } };
  const request = (path, { method = "GET", authorization, body } = {}) => {
    const headers = { upgrade: "websocket" };
    if (authorization) headers.authorization = authorization;
    return worker.fetch(new Request("https://test.invalid" + path, { method, headers, body }), env);
  };
  const authorize = JSON.stringify({ devices: [publicKey], enrollment });
  assert.equal(status(await request("/v2/authorize", { method: "POST", body: authorize })), 404);
  assert.equal(status(await request("/v2/authorize", { method: "POST", authorization: sender, body: authorize })), 204);
  assert.equal(status(await request("/v1/receiver/" + room)), 404);
  assert.equal(status(await request("/v2/sender", { authorization: sender })), 101);
  assert.equal(status(await request("/v2/enrollment-sender", { authorization: sender })), 101);
  assert.equal(status(await request("/v2/receiver/" + room)), 403);
  assert.equal(status(await request("/v2/enroll/" + room)), 403);
  assert.equal(status(await request("/v2/enroll/" + room, { authorization: "Bearer " + enrollment })), 101);
  assert.deepEqual(sockets.find(({ role }) => role === "sender").socket.sent, []);
  const stamp = Math.floor(Date.now() / 1000);
  const nonce = "03".repeat(16);
  const proof = async (method, signedRoom = room) => {
    const input = new TextEncoder().encode(["final-fusion-relay-v2", method, signedRoom, stamp, nonce].join(":"));
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.privateKey, input);
    return ["FF2", publicKey, stamp, nonce, hex(signature)].join(" ");
  };
  const path = "/v2/receiver/" + room;
  assert.equal(status(await request(path, { authorization: await proof("GET", "33".repeat(32)) })), 403);
  const head = await proof("HEAD");
  assert.equal(status(await request(path, { method: "HEAD", authorization: head })), 204);
  assert.equal(status(await request(path, { authorization: head })), 403);
  const authorized = await proof("GET");
  assert.equal(status(await request(path, { authorization: authorized })), 101);
  assert.equal(status(await request(path, { authorization: authorized })), 409);
  assert.equal(status(await request("/v2/release", { method: "POST", authorization: sender })), 409);
  const enrollmentSocket = sockets.find(({ role }) => role === "enroll").socket;
  instance.webSocketClose(enrollmentSocket);
  assert.equal(sockets.find(({ role }) => role === "sender").socket.readyState, 1);
  const active = sockets.find(({ role }) => role === "receiver").socket;
  active.close();
  instance.webSocketClose(active);
  assert.equal(status(await request("/v2/sender", { authorization: sender })), 101);
  assert.equal(status(await request(path, { authorization: authorized })), 403);
});
