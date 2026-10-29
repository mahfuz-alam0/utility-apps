// One download: several parallel Range fetches, each written straight into the OPFS file at its own offset
// (like pwrite), so nothing is held in memory and a pause keeps every byte received.
importScripts("lib.js");

let stopped = false;
const ctrl = new AbortController();
onmessage = ({ data }) => (data.cmd === "stop" ? ((stopped = true), ctrl.abort()) : start(data));

async function start({ job, conns, fresh }) {
  const segs = job.segs;
  const sync = await (await (await navigator.storage.getDirectory()).getFileHandle(job.id, { create: true })).createSyncAccessHandle();
  if (fresh || sync.getSize() !== job.total) {  // new file, or the file on disk is not what the progress says: start over
    segs.forEach((g) => (g.d = 0));
    sync.truncate(0);
    sync.truncate(job.total);
  }

  let got = 0, speed = 0, error = null;
  const timer = setInterval(() => {
    speed = speed ? speed * 0.6 + (got / 0.5) * 0.4 : got / 0.5;
    got = 0;
    sync.flush();
    postMessage({ type: "progress", segs, speed });
  }, 500);

  async function piece(g) {
    for (let tries = 0; !stopped && g.s + g.d <= g.e; ) {
      try {
        const res = await fetch(job.resolved || job.url, {
          headers: {
            Range: `bytes=${g.s + g.d}-${g.e}`,
            // if the file changed since we started the server answers 200 instead of 206, and we stop
            ...(job.validator && !job.validator.startsWith("W/") ? { "If-Range": job.validator } : {}),
          },
          credentials: "include", cache: "no-store", signal: ctrl.signal,
        });
        if (res.status !== 206 || res.headers.get("content-encoding")) {
          throw Object.assign(new Error(res.status === 200 ? "File changed on the server" : res.status === 206 ? "Server compressed the download" : `HTTP ${res.status}`),
                              { fatal: res.status !== 429 && res.status < 500 });
        }
        const reader = res.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          const chunk = value.subarray(0, g.e - (g.s + g.d) + 1);  // never past the piece's end
          sync.write(chunk, { at: g.s + g.d });
          g.d += chunk.length;
          got += chunk.length;
          tries = 0;
        }
        if (g.s + g.d <= g.e) throw new Error("Connection closed early");
      } catch (e) {
        if (stopped) return;
        if (e.fatal || ++tries > 4) throw e;
        await new Promise((r) => setTimeout(r, tries * 1000));  // retry from where this piece stopped
      }
    }
  }

  const busy = new Set();
  const lane = async () => {
    for (;;) {
      const i = segs.findIndex((g, k) => g.s + g.d <= g.e && !busy.has(k));
      if (i < 0 || stopped) return;
      busy.add(i);
      try { await piece(segs[i]); } finally { busy.delete(i); }
    }
  };
  await Promise.all(Array.from({ length: conns }, () => lane().catch((e) => { error ||= e; stopped = true; ctrl.abort(); })));

  clearInterval(timer);
  sync.flush();
  sync.close();
  const complete = segs.every((g) => g.s + g.d > g.e);
  postMessage({ type: error ? "error" : complete ? "done" : "stopped", segs, speed: 0, error: error?.message });
}
