import { test } from "node:test";
import assert from "node:assert/strict";
import { kgToLb, mToMi, paceSecPerKmToSecPerMi, fmtPace, fmtHM } from "./units.js";

test("kgToLb", () => assert.ok(Math.abs(kgToLb(75) - 165.347) < 1e-3));
test("mToMi", () => assert.equal(mToMi(1609.344), 1));
test("pace conversion", () => assert.ok(Math.abs(paceSecPerKmToSecPerMi(360) - 579.36) < 0.01));
test("fmtPace", () => assert.equal(fmtPace(579.36), "9:39"));
test("fmtHM", () => assert.equal(fmtHM(7.7), "7 h 42 m"));
test("null passthrough", () => {
  for (const f of [kgToLb, mToMi, paceSecPerKmToSecPerMi, fmtPace, fmtHM]) {
    assert.equal(f(null), null);
    assert.equal(f(undefined), null);
  }
});
