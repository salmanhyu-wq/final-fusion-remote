"use strict";
const el = (id) => document.getElementById(id);
// Follow the system language (Windows passes it to Edge/Chrome).
const KO = /^ko\b/i.test((navigator.languages && navigator.languages[0]) || navigator.language || "");
const T = (ko, en) => KO ? ko : en;
const EN = {
  title: "Final Fusion Viewer", product: "Final Fusion", subtitle: "Use your Mac from this PC",
  heading: "Connect to your host Mac", lead: "Click “Start sharing” on the host Mac, then connect. A 6-digit code appears the first time.",
  ready: "Ready.", connect: "Connect", disconnect: "Disconnect", quality: "Quality", low: "Low", medium: "Medium", high: "High",
  diagnostics: "Share connection stats with the host Mac", tuning: "Let the host Mac change the quality",
  trouble: "Can't connect?", speed: "Recommended internet speed: 25 Mbps down, 2 Mbps up.",
  help: "Check your internet and make sure the host Mac is sharing, then click <b>Connect</b>. The first time, enter the 6-digit code shown here on the host Mac.",
  agent: "Copy AI assistant guide", promo: "Turn your story into a song · get two versions", promoCta: "Make a song →",
  exit: "Quit", screens: "Shared displays", keyboard: "Keyboard",
  kbMac: "Mac keyboard (⌘ in the Windows key spot)", kbPc: "Windows keyboard (Mac key order)",
  fullscreenTip: "In “Full screen”, system keys such as the Windows key and Alt+Tab also go to the Mac. Hold Esc to leave full screen."
};
document.documentElement.lang = KO ? "ko" : "en";
if (!KO) {
  for (const node of document.querySelectorAll("[data-i18n]")) if (EN[node.dataset.i18n]) node.textContent = EN[node.dataset.i18n];
  for (const node of document.querySelectorAll("[data-i18n-html]")) if (EN[node.dataset.i18nHtml]) node.innerHTML = EN[node.dataset.i18nHtml];
  for (const node of document.querySelectorAll("[data-i18n-label]")) if (EN[node.dataset.i18nLabel]) node.setAttribute("aria-label", EN[node.dataset.i18nLabel]);
  document.title = EN.title;
}
const status = (text, tone = el("state").dataset.tone) => {
  el("state").dataset.tone = tone;
  el("status").textContent = text;
};
const screens = new Map();
const utf8 = new TextDecoder();
let generation = 0, active = false, playing = false, pulse, pending = [], writing = false;
let controller, exiting = false;
let sessionID, lastReportAt = 0, roundTripMS;
const clientVersion = el("version").textContent;
const sendDiagnostics = el("sendDiagnostics");
const remoteTuning = el("remoteTuning");
const post = (name, options = {}) => fetch(name, { method: "POST", ...options });
const resolution = el("quality");
const keyboardChoice = el("keyboard");
// "mac" when this PC is Apple hardware running Windows (Boot Camp); the Windows app fills it in.
const detectedKeyboard = document.querySelector('meta[name="studio-keyboard"]')?.content === "mac" ? "mac" : "pc";
const macLayout = () => (keyboardChoice.value === "auto" ? detectedKeyboard : keyboardChoice.value) === "mac";
try {
  const stored = localStorage.getItem("resolution");
  if (["0", "1", "2"].includes(stored)) resolution.value = stored;
  resolution.onchange = () => localStorage.setItem("resolution", resolution.value);
  const layout = localStorage.getItem("keyboard");
  if (["auto", "mac", "pc"].includes(layout)) keyboardChoice.value = layout;
} catch (_) {}
keyboardChoice.options[0].textContent = T("자동 · ", "Auto · ") + (detectedKeyboard === "mac" ? T("맥 키보드", "Mac keyboard") : T("Windows 키보드", "Windows keyboard"));
function updateKeyboardTip() {
  el("keyboardTip").textContent = macLayout()
    ? T("맥 키보드 배열: ⌘(Windows 키 자리)+C 복사, ⌘+Space Spotlight. 한/영 키는 맥의 입력 전환으로 보내요.",
        "Mac layout: ⌘ (Windows key spot)+C copies, ⌘+Space opens Spotlight. The Korean/English key switches the Mac's input.")
    : T("Windows 키보드는 놓인 순서대로 Ctrl·Win·Alt가 맥의 Control·Option·Command가 돼요. 예: Alt+C 복사, Alt+Space Spotlight. 한/영 키는 맥의 입력 전환으로 보내요.",
        "Windows keyboard: Ctrl·Win·Alt act as the Mac's Control·Option·Command in the same order, e.g. Alt+C copies and Alt+Space opens Spotlight. The Korean/English key switches the Mac's input.");
}
keyboardChoice.onchange = () => { try { localStorage.setItem("keyboard", keyboardChoice.value); } catch (_) {} updateKeyboardTip(); };
updateKeyboardTip();

function screenRequest() {
  const w = Math.round(window.screen.width), h = Math.round(window.screen.height);
  if (w < 640 || h < 480 || w > 8192 || h > 8192) return "";
  let divisor = w, rest = h;
  while (rest) [divisor, rest] = [rest, divisor % rest];
  const unitW = w / divisor, unitH = h / divisor;
  const scale = [16, 18, 21][Number(resolution.value)] ?? 18;
  const units = Math.min(Math.round(divisor * scale / 16), Math.floor(8192 / Math.max(unitW, unitH)));
  return "?" + new URLSearchParams({ width: unitW * units, height: unitH * units });
}

async function copy(text, message) {
  try { await navigator.clipboard.writeText(text); status(message); }
  catch { status(T("복사하지 못했어요. 이 글을 선택해서 복사하세요: ", "Couldn't copy. Select this text and copy it: ") + text); }
}
let agent = "";
fetch(KO ? "agent" : "agent-en").then(r => r.text()).then(v => { agent = v; }).catch(() => {});
el("agent").onclick = () => { if (agent) copy(agent, T("복사했어요. AI 도우미에 붙여넣으세요.", "Copied. Paste it into an AI assistant.")); };
el("disconnect").onclick = () => stop(T("연결을 끊었어요.", "Disconnected."));
el("exit").onclick = () => { exiting = true; stop(T("앱을 닫았어요.", "Closed the app.")); void post("exit"); el("connect").disabled = true; };
el("connect").onclick = () => { void connect(); };
async function connect(retries = 0) {
  if (active) return;
  if (typeof VideoDecoder === "undefined") { status(T("최신 Edge 또는 Chrome에서 열어 주세요.", "Please open this in the latest Edge or Chrome."), "attention"); return; }
  active = true;
  const run = ++generation;
  sessionID = globalThis.crypto?.randomUUID?.();
  roundTripMS = undefined;
  el("connect").disabled = true; el("disconnect").disabled = false; resolution.disabled = true;
  status(T("보내는 맥에 연결하는 중…", "Connecting to the host Mac…"), "busy");
  controller = new AbortController();
  try {
    const started = await post("connect" + screenRequest(), { signal: controller.signal });
    if (!started.ok) throw Error((await started.text()).trim());
    const response = await fetch("stream", { signal: controller.signal });
    if (!response.ok || !response.body) throw Error(T("화면을 받을 수 없어요.", "Couldn't receive the screen."));
    const reader = new FrameReader(response.body.getReader());
    while (run === generation) {
      const header = await reader.read(9);
      const view = new DataView(header.buffer);
      const id = view.getUint32(1), len = view.getUint32(5), kind = header[0];
      if (len > (kind === 4 ? 4 * 1024 * 1024 : 32768)) throw Error(T("잘못된 화면 데이터예요.", "Invalid screen data."));
      const bytes = await reader.read(len);
      if (run !== generation) break;
      if (kind === 2) {
        const displays = JSON.parse(utf8.decode(bytes));
        if (screens.size || !Array.isArray(displays) || displays.length < 1 || displays.length > 8) throw Error(T("화면 목록을 열 수 없어요.", "Couldn't open the screen list."));
        for (const display of displays) addScreen(display);
        // Keys go to the focused screen; focus the first one so typing works without a click first.
        if (!document.activeElement || document.activeElement === document.body || document.activeElement.id === "connect")
          el("screens").querySelector("canvas")?.focus({preventScroll: true});
        playing = true;
        lastReportAt = performance.now();
        pulse = setInterval(() => {
          void post("pulse?stamp=" + Date.now()).catch(() => {});
          reportDiagnostics();
        }, 1800);
        status(T("안전하게 연결됨 · 모니터 " + displays.length + "개", "Connected securely · " + displays.length + " display(s)"), "success");
      } else if (kind === 3) {
        configure(screens.get(id), bytes);
      } else if (kind === 4) {
        draw(screens.get(id), bytes);
      } else if (kind === 7) {
        throw Error(utf8.decode(bytes));
      } else if (kind === 8) {
        const code = utf8.decode(bytes);
        if (!/^\d{6}$/.test(code)) throw Error(T("6자리 번호를 읽지 못했어요.", "Couldn't read the 6-digit code."));
        status(T("6자리 번호 " + code + " · 보내는 맥의 ‘③ 첫 연결’ 칸에 이 번호를 입력하고 ‘허용’을 누르세요.", "6-digit code " + code + " · Enter it under “③ First connection” on the host Mac and click “Allow”."), "attention");
      } else if (kind === 6) {
        if (bytes.length === 8) {
          const rtt = Date.now() - Number(new DataView(bytes.buffer).getBigUint64(0));
          if (rtt >= 0 && rtt <= 10000) roundTripMS = rtt;
        }
      } else if (kind === 12) {
        if (bytes.length <= 1024) {
          try { applyReceiverResolution(JSON.parse(utf8.decode(bytes))); } catch (_) {}
        }
      } else {
        throw Error(T("화면 데이터를 읽지 못했어요.", "Couldn't read the screen data."));
      }
    }
  } catch (error) {
    if (run === generation) {
      // A connection that was already showing the screen dropped: reconnect a few times, like the Mac viewer.
      const dropped = playing, retry = dropped || retries > 0;
      const stopped = stop((error.message || T("연결이 끊겼어요.", "The connection dropped.")) + (dropped ? T(" 자동으로 다시 연결해요.", " Reconnecting automatically.") : ""), retry ? "busy" : "attention");
      if (retry) reconnectAfter(stopped, dropped ? 3 : retries - 1);
      else el("setup").open = true;
    }
  }
}

function reconnectAfter(stopped, retries) {
  const closed = generation;
  void stopped.then(() => {
    setTimeout(() => {
      if (closed === generation && !active && !exiting) void connect(retries);
    }, 2000);
  });
}

function applyReceiverResolution(command) {
  if (!playing || !sendDiagnostics.checked || !remoteTuning.checked || !sessionID ||
      typeof command?.session !== "string" || command.session.toLowerCase() !== sessionID.toLowerCase() ||
      !Number.isInteger(command.resolution) || ![0, 1, 2].includes(command.resolution) ||
      command.resolution === Number(resolution.value)) return;
  resolution.value = String(command.resolution);
  reconnectAfter(stop(T("화질을 바꾸고 다시 연결해요.", "Changing quality and reconnecting."), "busy"), 2);
}

function reportDiagnostics() {
  if (!playing || !sendDiagnostics.checked) return;
  const now = performance.now(), seconds = Math.round((now - lastReportAt) / 1000);
  if (seconds < 6) return;
  lastReportAt = now;
  const localWidth = Math.max(1, Math.round(window.screen.width * window.devicePixelRatio));
  const localHeight = Math.max(1, Math.round(window.screen.height * window.devicePixelRatio));
  const displays = Array.from(screens, ([id, state]) => {
    const {canvas, receivedFrames, submittedFrames} = state;
    state.receivedFrames = 0;
    state.submittedFrames = 0;
    const scale = Math.min(localWidth / canvas.width, localHeight / canvas.height);
    const fits = Math.abs(canvas.width * scale - localWidth) <= 2 &&
                 Math.abs(canvas.height * scale - localHeight) <= 2;
    return {id, localWidth, localHeight, receivedFrames, submittedFrames,
            fillsScreen: document.fullscreenElement === canvas && fits, localCursorHidden: false,
            pinchEvents: 0, multiTouchEvents: 0, gestureShortcuts: 0, nativeGestureEvents: 0, nativeGestures: 0};
  });
  if (seconds > 30) return;
  const report = {seconds, displays, roundTripMS};
  if (/^\d+\.\d+\.\d+$/.test(clientVersion)) report.clientVersion = clientVersion;
  if (sessionID) report.tuning = {session: sessionID, resolution: Number(resolution.value), allowed: remoteTuning.checked};
  void post("diagnostics", {headers: {"Content-Type": "application/json"}, body: JSON.stringify(report)}).catch(() => {});
}

function stop(reason, tone = "idle") {
  generation++; active = false; playing = false; pending = [];
  controller?.abort(); clearInterval(pulse);
  const closed = generation;
  const stopped = post("disconnect").catch(() => {}).finally(() => {
    if (closed === generation && !exiting) el("connect").disabled = false;
  });
  for (const state of screens.values()) if (state.decoder?.state !== "closed") state.decoder?.close();
  screens.clear();
  resolution.disabled = false;
  el("screens").replaceChildren();
  el("connect").disabled = true; el("disconnect").disabled = true;
  status(reason, tone);
  return stopped;
}

class FrameReader {
  constructor(reader) { this.reader = reader; this.chunk = new Uint8Array(0); this.offset = 0; }
  async read(size) {
    const result = new Uint8Array(size);
    let received = 0;
    while (received < size) {
      if (this.offset === this.chunk.length) {
        const {done, value} = await this.reader.read();
        if (done) throw Error(T("연결이 끊겼어요. 보내는 맥이 보내기 중인지 확인하세요.", "The connection dropped. Make sure the host Mac is sharing."));
        this.chunk = value; this.offset = 0;
      }
      const count = Math.min(size - received, this.chunk.length - this.offset);
      result.set(this.chunk.subarray(this.offset, this.offset + count), received);
      this.offset += count; received += count;
    }
    return result;
  }
}

function addScreen(d) {
  if (![d.id,d.width,d.height].every(Number.isInteger) || d.width < 2 || d.height < 2 ||
      d.width > 4096 || d.height > 4096 || screens.has(d.id)) throw Error(T("화면 크기가 올바르지 않아요.", "Invalid screen size."));
  const card = document.createElement("article"); card.className = "screen";
  const bar = document.createElement("div");
  const name = document.createElement("strong"); name.textContent = d.name;
  const full = document.createElement("button"); full.textContent = T("전체 화면", "Full screen");
  const canvas = document.createElement("canvas");
  canvas.width = d.width; canvas.height = d.height; canvas.tabIndex = 0;
  canvas.setAttribute("aria-label", d.name + T(" 원격 화면", " remote screen"));
  full.onclick = () => {
    canvas.focus();
    // Keyboard Lock (full screen only) lets the Windows key, Alt+Tab and similar keys reach the Mac.
    void canvas.requestFullscreen()
      .then(() => { navigator.keyboard?.lock?.().catch(() => {}); })
      .catch(() => status(T("브라우저에서 전체 화면을 열 수 없어요.", "The browser couldn't open full screen.")));
  };
  bar.append(name,full); card.append(bar,canvas); el("screens").append(card);
  const state = { canvas, context: canvas.getContext("2d", { alpha:false }), decoder:null, awaitKey:true, time:0, receivedFrames:0, submittedFrames:0 };
  screens.set(d.id,state);
  bindInput(canvas,d);
}

function configure(state,data) {
  if (!state || data.length < 16) return;
  const view = new DataView(data.buffer);
  const a = view.getUint32(0);
  if (a < 4 || a > 4000 || a+12 >= data.length) return;
  const b = view.getUint32(4+a);
  if (b < 1 || b > 4000 || a+b+12 !== data.length) return;
  const nal = view.getUint32(8+a+b);
  if (![1,2,4].includes(nal)) return;
  const sps = data.subarray(4,4+a), pps = data.subarray(8+a,8+a+b);
  const description = Uint8Array.from([1,sps[1],sps[2],sps[3],0xfc|(nal-1),0xe1,a>>8,a&255,...sps,1,b>>8,b&255,...pps]);
  const codec = "avc1." + [sps[1],sps[2],sps[3]].map(v=>v.toString(16).padStart(2,"0")).join("");
  if (state.decoder?.state !== "closed") state.decoder?.close();
  state.decoder = new VideoDecoder({
    output: frame => { try { state.context.drawImage(frame,0,0,state.canvas.width,state.canvas.height); } finally { frame.close(); } },
    error: () => { state.awaitKey = true; status(T("이 PC에서 화면을 표시하지 못했어요. Edge 또는 Chrome을 확인하세요.", "This PC couldn't display the screen. Check Edge or Chrome.")); }
  });
  state.config = {codec,description,optimizeForLatency:true,hardwareAcceleration:"prefer-hardware"};
  state.decoder.configure(state.config);
  state.awaitKey = true;
}
function draw(state,data) {
  if (state) state.receivedFrames++;
  if (!state?.decoder || state.decoder.state !== "configured" || data.length < 2) return;
  const key = data[0] === 1;
  if (state.decoder.decodeQueueSize > 4) {
    state.decoder.reset();
    state.decoder.configure(state.config);
    state.awaitKey = true;
  }
  if (!key && state.awaitKey) return;
  state.awaitKey = false;
  state.decoder.decode(new EncodedVideoChunk({type:key?"key":"delta",timestamp:++state.time*16667,data:data.subarray(1)}));
  state.submittedFrames++;
}

const keys = {
 KeyA:0,KeyS:1,KeyD:2,KeyF:3,KeyH:4,KeyG:5,KeyZ:6,KeyX:7,KeyC:8,KeyV:9,KeyB:11,KeyQ:12,KeyW:13,KeyE:14,KeyR:15,KeyY:16,KeyT:17,
 Digit1:18,Digit2:19,Digit3:20,Digit4:21,Digit6:22,Digit5:23,Equal:24,Digit9:25,Digit7:26,Minus:27,Digit8:28,Digit0:29,
 BracketRight:30,KeyO:31,KeyU:32,BracketLeft:33,KeyI:34,KeyP:35,Enter:36,KeyL:37,KeyJ:38,Quote:39,KeyK:40,Semicolon:41,Backslash:42,
 Comma:43,Slash:44,KeyN:45,KeyM:46,Period:47,Tab:48,Space:49,Backquote:50,Backspace:51,Escape:53,MetaRight:54,MetaLeft:55,
 ShiftLeft:56,AltLeft:58,ControlLeft:59,ShiftRight:60,AltRight:61,ControlRight:62,
 F1:122,F2:120,F3:99,F4:118,F5:96,F6:97,F7:98,F8:100,F9:101,F10:109,F11:103,F12:111,Delete:117,
 Home:115,End:119,PageUp:116,PageDown:121,ArrowLeft:123,ArrowRight:124,ArrowDown:125,ArrowUp:126,
 CapsLock:57,Lang1:57,Insert:114,IntlBackslash:10,IntlYen:93,IntlRo:94,
 Numpad0:82,Numpad1:83,Numpad2:84,Numpad3:85,Numpad4:86,Numpad5:87,Numpad6:88,Numpad7:89,Numpad8:91,Numpad9:92,
 NumpadDecimal:65,NumpadMultiply:67,NumpadAdd:69,NumLock:71,NumpadDivide:75,NumpadEnter:76,NumpadSubtract:78,NumpadEqual:81,
 F13:105,F14:107,F15:113,F16:106,F17:64,F18:79,F19:80,F20:90,AudioVolumeUp:72,AudioVolumeDown:73,AudioVolumeMute:74
};
// Windows keyboards keep their physical order: Ctrl, Win, Alt become Control, Option, Command.
const pcSwap = {AltLeft:"MetaLeft",MetaLeft:"AltLeft",AltRight:"MetaRight",MetaRight:"AltRight"};
const keyboardCode = code => macLayout() ? code : (pcSwap[code] || code);
const flags = e => { const mac = macLayout(); return (e.shiftKey ? 1<<17 : 0) | (e.ctrlKey ? 1<<18 : 0) |
  ((mac ? e.altKey : e.metaKey) ? 1<<19 : 0) | ((mac ? e.metaKey : e.altKey) ? 1<<20 : 0); };
const event = (action,id=0,x=0,y=0,a=0,b=0,f=0) => ({action,display:id,x,y,a,b,flags:f});
function enqueue(value) {
  if (!playing) return;
  if (value.action === "move" && pending.at(-1)?.action === "move") pending[pending.length-1] = value;
  else pending.push(value);
  if (pending.length > 160) { stop(T("입력이 밀려서 연결을 끊었어요.", "Input was delayed too long, so the connection was closed.")); return; }
  if (!writing) void flushInput();
}
async function flushInput() {
  writing = true;
  const run = generation;
  try {
    while (playing && pending.length && run === generation) {
      const result = await post("input",{ headers:{"Content-Type":"application/json"},body:JSON.stringify(pending.splice(0,40)) });
      if (!result.ok) throw Error(T("키보드나 마우스 입력을 보낼 수 없어요.", "Couldn't send keyboard or mouse input."));
    }
  } catch (error) { if (run === generation) stop(error.message); }
  finally { writing = false; if (playing && pending.length) void flushInput(); }
}
function bindInput(canvas,d) {
  canvas.oncontextmenu = e => e.preventDefault();
  canvas.onblur = () => enqueue(event("release"));
  const point = e => {
    const r = canvas.getBoundingClientRect(), scale = Math.min(r.width/d.width,r.height/d.height);
    const w = d.width*scale, h = d.height*scale;
    const clamp = x => Math.min(1,Math.max(0,x));
    return [clamp((e.clientX-r.left-(r.width-w)/2)/w),clamp((e.clientY-r.top-(r.height-h)/2)/h)];
  };
  let button = 0, last = 0;
  const translated = e => e.button === 2 ? 1 : e.button === 1 ? 2 : 0;
  canvas.onpointerdown = e => { e.preventDefault(); canvas.focus(); canvas.setPointerCapture(e.pointerId); button=translated(e); enqueue(event("down",d.id,...point(e),button,e.detail || 1,flags(e))); };
  canvas.onpointerup = e => enqueue(event("up",d.id,...point(e),translated(e),e.detail || 1,flags(e)));
  canvas.onpointercancel = () => enqueue(event("release"));
  canvas.onpointermove = e => { if(e.timeStamp-last>9){last=e.timeStamp;enqueue(event("move",d.id,...point(e),button,0,flags(e)));} };
  canvas.addEventListener("wheel",e=>{e.preventDefault();const s=e.deltaMode===1?12:1;enqueue(event("scroll",d.id,...point(e),Math.round(-e.deltaY*s),Math.round(-e.deltaX*s),flags(e)));},{passive:false});
  for (const action of ["keydown","keyup"]) {
    canvas.addEventListener(action,e=>{
      const code = keyboardCode(e.code);
      if (!(code in keys)) return;
      e.preventDefault();
      const down = action === "keydown";
      if (code === "Lang1") {
        // 한/영 often sends no key-up; tap Caps Lock, the Mac's Korean/English switch.
        if (down && !e.repeat) { enqueue(event("flags",d.id,0,0,57,1,flags(e)|1<<16)); enqueue(event("flags",d.id,0,0,57,0,flags(e))); }
        return;
      }
      if (code === "CapsLock") { if (!e.repeat) enqueue(event("flags",d.id,0,0,57,down?1:0,flags(e)|(down?1<<16:0))); return; }
      const modifier = /^(Shift|Control|Alt|Meta)/.test(code);
      if (modifier && e.repeat) return;
      const value = event(modifier?"flags":down?"keyDown":"keyUp",d.id,0,0,keys[code],down?1:0,flags(e));
      if (down && e.repeat) value.repeatKey = true;
      enqueue(value);
    });
  }
}
window.addEventListener("blur",()=>enqueue(event("release")));
document.addEventListener("fullscreenchange",()=>{ if (!document.fullscreenElement) navigator.keyboard?.unlock?.(); });
window.addEventListener("pagehide",()=>{ void post("disconnect",{keepalive:true}).catch(()=>{}); });
el("connect").click();
