import { test } from "node:test";
import assert from "node:assert/strict";
import { fmtUSD, fmtUSDWhole, categoryLabel } from "./money.js";

test("fmtUSD formats cents with grouping", () => assert.equal(fmtUSD(1234.5), "$1,234.50"));
test("fmtUSD uses a true minus sign for negatives", () => assert.equal(fmtUSD(-12), "−$12.00"));
test("fmtUSD shows a dash for missing values", () => {
  assert.equal(fmtUSD(null), "–");
  assert.equal(fmtUSD(undefined), "–");
});
test("fmtUSDWhole rounds to dollars", () => assert.equal(fmtUSDWhole(1234.5), "$1,235"));
test("categoryLabel turns Plaid codes into plain words", () => {
  assert.equal(categoryLabel("FOOD_AND_DRINK"), "Food & drink");
  assert.equal(categoryLabel("GENERAL_MERCHANDISE"), "General merchandise");
  assert.equal(categoryLabel("TRANSFER_IN"), "Transfer in");
});
