import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import { bearerDecision, busWriteDecision, telemetryLog } from "./ownership.mjs";

const pilot = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

describe("telemetry ownership proposal", () => {
  it("rejects a missing or malformed bearer before a bus decision", () => {
    assert.equal(bearerDecision(null).status, 401);
    assert.equal(bearerDecision("Bearer not-a-jwt").code, "UNAUTHORIZED_INVALID_JWT_FORMAT");
    assert.equal(bearerDecision("Bearer aaa.bbb.ccc").ok, true);
  });

  it("allows only the assigned pilot", () => {
    assert.equal(busWriteDecision({ userId: pilot, assignedPilotId: pilot }), "allowed");
    assert.equal(busWriteDecision({ userId: other, assignedPilotId: pilot }), "forbidden");
    assert.equal(busWriteDecision({ userId: null, assignedPilotId: pilot }), "unauthorized");
    assert.equal(busWriteDecision({ userId: pilot, assignedPilotId: null }), "forbidden");
  });

  it("omits tokens and student fields from logs", () => {
    assert.deepEqual(telemetryLog("denied", { bus_id: "b1", authorization: "hidden", student_id: "hidden" }), {
      event: "denied",
      bus_id: "b1",
    });
  });

  it("inserts only after the pilot check and does not use the service role", () => {
    const source = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
    assert.equal(source.includes("SUPABASE_SERVICE_ROLE_KEY"), false);
    assert.equal(source.includes("busWriteDecision"), true);
    assert.equal(source.indexOf("busWriteDecision") < source.indexOf(".insert("), true);
  });
});
