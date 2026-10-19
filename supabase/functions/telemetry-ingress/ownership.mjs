/** Local proposal. Not deployed. A JWT does not authorize every bus. */

export function bearerDecision(authorizationHeader) {
  const header = authorizationHeader ?? "";
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  if (!match) return { ok: false, status: 401, error: "Missing bearer token." };
  const token = match[1];
  if (token.split(".").length !== 3) {
    return {
      ok: false,
      status: 401,
      code: "UNAUTHORIZED_INVALID_JWT_FORMAT",
      message: "Invalid JWT",
    };
  }
  return { ok: true, token };
}

export function busWriteDecision({ userId, assignedPilotId }) {
  if (!userId) return "unauthorized";
  if (!assignedPilotId || assignedPilotId !== userId) return "forbidden";
  return "allowed";
}

const sensitiveKey = /authorization|token|password|secret|pin|student/i;

export function telemetryLog(event, fields = {}) {
  const safe = { event };
  for (const [key, value] of Object.entries(fields)) {
    if (sensitiveKey.test(key)) continue;
    safe[key] = value;
  }
  return safe;
}
