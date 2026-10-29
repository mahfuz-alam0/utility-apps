// Service worker: catches browser downloads, hands them to the engine page, saves what the engine finishes.
// It sleeps when idle, so it holds no state; the engine page (engine.js) does the actual work.

const enabled = async () => (await chrome.storage.local.get({ enabled: true })).enabled;

let creating;
async function ensureEngine() {
  if ((await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] })).length) return;
  creating ??= chrome.offscreen
    .createDocument({ url: "engine.html", reasons: ["BLOBS"], justification: "Assemble the downloaded pieces and hand the file to the browser" })
    .finally(() => (creating = null));
  await creating;
}

async function engine(msg) {
  await ensureEngine();
  for (let i = 0; ; i++) {
    try {
      return await chrome.runtime.sendMessage({ ...msg, to: "engine" });
    } catch (e) {
      if (i >= 5) throw e;  // the page may still be starting
      await new Promise((r) => setTimeout(r, 100));
    }
  }
}

chrome.downloads.onCreated.addListener(async (d) => {
  const url = d.finalUrl || d.url;
  // not blob:/data:, not another extension's download (ours included), not private windows (the pieces would be stored on disk)
  if (!/^https?:/.test(url) || d.byExtensionId || d.incognito || !(await enabled())) return;
  try {
    // The engine probes first and only takes files it can speed up (big, server supports ranges).
    // Anything else: the browser keeps its own download untouched.
    if ((await engine({ cmd: "add", url }))?.ok) {
      await chrome.downloads.cancel(d.id);
      await chrome.downloads.erase({ id: d.id });
    }
  } catch {}
});

// the engine's finished file is a blob: URL; saving it is a normal browser download
chrome.downloads.onChanged.addListener(async (delta) => {
  const state = delta.state?.current;
  if (state !== "complete" && state !== "interrupted") return;
  const [d] = await chrome.downloads.search({ id: delta.id });
  if (d?.url?.startsWith(`blob:chrome-extension://${chrome.runtime.id}/`)) {
    engine({ cmd: "saved", url: d.url, id: d.id, ok: state === "complete", error: d.error });
  }
});

// from the engine ("save") and the popup (pause/resume/remove/…, passed on to the engine)
chrome.runtime.onMessage.addListener((m, _sender, reply) => {
  if (m.to !== "bg") return;
  (async () => {
    if (m.cmd === "save") {
      reply(await chrome.downloads.download({ url: m.url, filename: m.name, conflictAction: "uniquify" }).catch((e) => ({ error: String(e.message || e) })));
    } else {
      reply(await engine(m));
    }
  })();
  return true;
});

const badge = async () => chrome.action.setBadgeText({ text: (await enabled()) ? "" : "OFF" });
chrome.storage.onChanged.addListener(badge);
badge();
