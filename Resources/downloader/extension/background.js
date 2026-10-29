const APP = "http://127.0.0.1:48620";

chrome.downloads.onCreated.addListener(async (d) => {
  const url = d.finalUrl || d.url;
  if (!/^https?:/.test(url) || d.byExtensionId) return;  // skip blob:/data: and downloads started by extensions
  try {
    // app closed or switch off: the browser keeps its own download
    const { capture } = await (await fetch(`${APP}/status`)).json();
    if (!capture) return;
    // the site may need the browser's login: pass its cookies and referrer along
    const cookie = (await chrome.cookies.getAll({ url })).map((c) => `${c.name}=${c.value}`).join("; ");
    const r = await fetch(`${APP}/add`, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },  // no preflight
      body: JSON.stringify({ url, referrer: d.referrer, cookie }),
    });
    if (r.ok) {  // only drop the browser's copy once the app has taken it
      await chrome.downloads.cancel(d.id);
      await chrome.downloads.erase({ id: d.id });
    }
  } catch {}
});
