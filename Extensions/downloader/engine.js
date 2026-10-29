// Offscreen page: lives as long as the browser (the service worker would be killed mid-download).
// Owns the job list and runs one Worker per active job. The job list is kept in localStorage: the popup shares this
// origin, so it can read the list and gets `storage` events whenever it changes.

let jobs = JSON.parse(localStorage.jobs || "[]");
const workers = new Map();  // job id -> Worker
const save = () => (localStorage.jobs = JSON.stringify(jobs));
const find = (id) => jobs.find((j) => j.id === id);
const connections = () => Math.max(1, Math.min(16, Number(localStorage.conns) || 8));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const opfs = () => navigator.storage.getDirectory();

// the page was (re)created, so nothing is running: whatever was in flight is paused
for (const j of jobs) if (j.state === "downloading" || j.state === "saving") j.state = "paused";
save();
(async () => { for await (const name of (await opfs()).keys()) if (!find(name)) removeFile(name); })();  // orphaned pieces

async function removeFile(name) {
  for (let i = 0; i < 5; i++) {
    try { return await (await opfs()).removeEntry(name); }
    catch (e) { if (e.name === "NotFoundError") return; await sleep(300); }  // a just-stopped worker may still hold it
  }
}

/** Range 0-0: a 206 with Content-Range gives the size and proves the server supports ranges, in one tiny request. */
async function probe(url, min = MIN_SIZE) {
  const ctrl = new AbortController();
  try {
    const r = await fetch(url, { headers: { Range: "bytes=0-0" }, credentials: "include", cache: "no-store", signal: ctrl.signal });
    const total = r.status === 206 ? Number(/\/(\d+)$/.exec(r.headers.get("content-range") || "")?.[1]) : NaN;
    return {
      // a compressed body would not match the byte ranges
      ok: total >= min && !r.headers.get("content-encoding"),
      total,
      url: r.url,
      name: safeName(nameFrom(r.headers.get("content-disposition"), r.url)),
      validator: r.headers.get("etag") || r.headers.get("last-modified"),
    };
  } catch {
    return { ok: false };
  } finally {
    ctrl.abort();  // a server that ignores Range starts sending the whole file: drop it
  }
}

async function add(url) {
  const p = await probe(url);
  if (!p.ok) return { ok: false };
  const job = { id: crypto.randomUUID(), url, resolved: p.url, name: p.name, total: p.total, validator: p.validator,
                segs: split(p.total, connections() * 4), state: "downloading", speed: 0 };
  jobs.unshift(job);
  run(job, true);
  return { ok: true };
}

function run(job, fresh) {
  const w = new Worker("worker.js");
  workers.set(job.id, w);
  Object.assign(job, { state: "downloading", error: null });
  save();
  w.onmessage = ({ data: m }) => {
    Object.assign(job, { segs: m.segs, speed: m.speed });
    if (m.type !== "progress") {
      w.terminate();
      workers.delete(job.id);
      if (m.type === "done") handoff(job);
      else Object.assign(job, m.type === "error" ? { state: "failed", error: m.error } : { state: "paused" });
    }
    save();
  };
  w.postMessage({ cmd: "start", job, conns: connections(), fresh });
}

/** All pieces are in the file: give it to the browser as a normal download (the background page calls downloads.download). */
async function handoff(job) {
  Object.assign(job, { state: "saving", speed: 0 });
  save();
  try {
    job.blob = URL.createObjectURL(await (await (await opfs()).getFileHandle(job.id)).getFile());
    save();
    const r = await chrome.runtime.sendMessage({ to: "bg", cmd: "save", url: job.blob, name: job.name });
    if (r?.error) throw new Error(r.error);
  } catch (e) {
    Object.assign(job, { state: "failed", error: String(e.message || e) });
    save();
  }
}

async function resume(j) {
  if (!j || workers.has(j.id) || j.state === "saving" || j.state === "done") return;
  if (j.segs.every((g) => g.s + g.d > g.e)) return handoff(j);  // everything was fetched, only the save failed
  Object.assign(j, { state: "downloading", error: null });
  save();
  const p = await probe(j.url, 0);  // fresh redirect target (links can expire), and is it still the same file?
  if (!p.ok) {
    Object.assign(j, { state: "failed", error: "The server did not answer" });
    return save();
  }
  const changed = p.total !== j.total || p.validator !== j.validator;
  if (changed) Object.assign(j, { total: p.total, validator: p.validator, segs: split(p.total, connections() * 4) });
  j.resolved = p.url;
  run(j, changed);
}

async function remove(j) {
  if (!j) return;
  workers.get(j.id)?.terminate();
  workers.delete(j.id);
  jobs = jobs.filter((x) => x !== j);
  save();
  if (j.blob) URL.revokeObjectURL(j.blob);
  removeFile(j.id);
}

chrome.runtime.onMessage.addListener((m, _sender, reply) => {
  if (m.to !== "engine") return;
  (async () => {
    switch (m.cmd) {
      case "add": return reply(await add(m.url));
      case "pause": workers.get(m.id)?.postMessage({ cmd: "stop" }); break;
      case "resume": await resume(find(m.id)); break;
      case "remove": await remove(find(m.id)); break;
      case "clear": jobs = jobs.filter((j) => j.state !== "done"); save(); break;
      case "saved": {  // the browser finished (or failed) saving our blob
        const j = jobs.find((x) => x.blob === m.url);
        if (j) {
          URL.revokeObjectURL(j.blob);
          delete j.blob;
          if (m.ok) { Object.assign(j, { state: "done", dlid: m.id }); removeFile(j.id); }
          else Object.assign(j, { state: "failed", error: m.error || "Saving failed" });
          save();
        }
        break;
      }
    }
    reply(true);
  })();
  return true;
});
