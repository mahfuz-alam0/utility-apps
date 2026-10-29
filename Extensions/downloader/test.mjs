// node test.mjs — the pure helpers in lib.js. (The download itself needs a browser: see README.)
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

vm.runInThisContext(fs.readFileSync(new URL("./lib.js", import.meta.url), "utf8"));
const run = (code) => vm.runInThisContext(code);

// split: contiguous, covers everything exactly once, min piece size
const s = run("split(10_000_001, 8)");
assert.equal(s.length, 8);
assert.equal(s[0].s, 0);
assert.equal(s.at(-1).e, 10_000_000);
s.slice(1).forEach((g, i) => assert.equal(g.s, s[i].e + 1));
assert.equal(run("split(100, 8)").length, 1);  // below one piece: not worth cutting
assert.deepEqual(run("split(0, 8)"), []);

// names
assert.equal(run(`nameFrom('attachment; filename="a b.zip"', "http://x/y")`), "a b.zip");
assert.equal(run(`nameFrom("attachment; filename*=UTF-8''na%C3%AFve%20file.zip", "http://x/y")`), "naïve file.zip");
assert.equal(run(`nameFrom(null, "http://x/dir/my%20file.iso?token=1")`), "my file.iso");
assert.equal(run(`nameFrom(null, "http://x/")`), "download");
assert.equal(run(`safeName("../.x/y:z")`), "_.x_y_z");

console.log("ok");
