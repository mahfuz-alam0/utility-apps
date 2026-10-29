// Shared by the engine page, the worker and test.mjs. Plain script (no modules) so importScripts() can load it too.
const MIN_PIECE = 1 << 20;  // never cut a piece smaller than 1 MiB
const MIN_SIZE = 4 << 20;   // below 4 MiB the browser alone is fast enough: leave those downloads alone

/** About `parts` pieces of at least MIN_PIECE bytes, covering 0..total-1. More pieces than connections, so a fast
 * connection takes the next piece instead of idling while a slow one finishes. s = start, e = end (inclusive), d = bytes done. */
function split(total, parts) {
  if (total <= 0) return [];
  const n = Math.max(1, Math.min(parts, Math.floor(total / MIN_PIECE)));
  const size = Math.ceil(total / n);
  const out = [];
  for (let s = 0; s < total; s += size) out.push({ s, e: Math.min(s + size, total) - 1, d: 0 });
  return out;
}

function safeName(n) {
  return n.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_").replace(/^\.+/, "").trim() || "download";
}

/** File name from Content-Disposition, else the last part of the URL. */
function nameFrom(contentDisposition, url) {
  const star = /filename\*\s*=\s*[^']*'[^']*'([^;]+)/i.exec(contentDisposition || "");
  if (star) try { return decodeURIComponent(star[1].trim()); } catch {}
  const plain = /filename\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;]+))/i.exec(contentDisposition || "");
  if (plain) return (plain[1] ?? plain[2]).trim();
  try { return decodeURIComponent(new URL(url).pathname.split("/").pop()) || "download"; } catch { return "download"; }
}
