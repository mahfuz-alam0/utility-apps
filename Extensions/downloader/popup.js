// The job list lives in localStorage (written by engine.js, same origin); `storage` events fire whenever it changes.
const $ = (id) => document.getElementById(id);
const send = (m) => chrome.runtime.sendMessage({ to: "bg", ...m });

const bytes = (n) => (n >= 1e9 ? `${(n / 1e9).toFixed(2)} GB` : n >= 1e6 ? `${(n / 1e6).toFixed(1)} MB` : `${Math.round(n / 1e3)} KB`);
const clock = (s) => (s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m` : s >= 60 ? `${Math.floor(s / 60)}m ${Math.round(s % 60)}s` : `${Math.round(s)}s`);

function el(tag, props, ...kids) {
  const e = Object.assign(document.createElement(tag), props);  // textContent only: file names are untrusted
  e.append(...kids);
  return e;
}

function row(j) {
  const got = j.segs.reduce((n, g) => n + g.d, 0);
  const btn = (label, title, fn) => el("button", { textContent: label, title, onclick: fn });
  const buttons = {
    downloading: [btn("⏸", "Pause", () => send({ cmd: "pause", id: j.id }))],
    paused: [btn("▶", "Resume", () => send({ cmd: "resume", id: j.id }))],
    failed: [btn("↻", "Retry", () => send({ cmd: "resume", id: j.id }))],
    saving: [],
    done: [btn("📂", "Show in folder", () => chrome.downloads.show(j.dlid))],
  }[j.state];
  const status = {
    downloading: `${bytes(got)} of ${bytes(j.total)}` + (j.speed > 0 ? ` · ${bytes(j.speed)}/s · ${clock((j.total - got) / j.speed)} left` : ""),
    paused: `Paused · ${bytes(got)} of ${bytes(j.total)}`,
    saving: "Saving…",
    done: bytes(j.total),
    failed: j.error || "Failed",
  }[j.state];
  return el("div", { className: "job" },
    el("div", { className: "top" }, el("span", { className: "name", textContent: j.name, title: j.name }), ...buttons,
       btn("✕", "Remove from list", () => send({ cmd: "remove", id: j.id }))),
    ...(j.state === "done" ? [] : [el("progress", { max: j.total, value: got })]),
    el("div", { className: j.state === "failed" ? "sub err" : "sub", textContent: status }));
}

function render() {
  const jobs = JSON.parse(localStorage.jobs || "[]");
  $("list").replaceChildren(...(jobs.length ? jobs.map(row) : [el("div", { className: "empty", textContent: "Downloads you start in the browser show up here." })]));
}

chrome.storage.local.get({ enabled: true }).then(({ enabled }) => ($("on").checked = enabled));
$("on").onchange = () => chrome.storage.local.set({ enabled: $("on").checked });
$("conns").value = localStorage.conns || 8;
$("conns").onchange = () => (localStorage.conns = Math.max(1, Math.min(16, Number($("conns").value) || 8)));
$("clear").onclick = () => send({ cmd: "clear" });
addEventListener("storage", render);
render();
send({ cmd: "hello" });  // makes sure the engine page exists, so jobs left "downloading" by a browser restart show as paused
