// Verifies the login tokens issued by club-membership-service.
// This service never signs tokens and never holds a private key. It gets
// Membership's PUBLIC key as JWT_PUBLIC_KEY_B64 (base64 of the PEM), set by
// infra/deploy.sh. Only RS256 with the agreed issuer and audience is
// accepted, so "alg: none", HS256 tricks, expired and foreign tokens fail.
const jwt = require("jsonwebtoken");

const ISSUER = "club-membership";
const AUDIENCE = "campus-club";
const ROLES = ["member", "officer"];

const PUBLIC_KEY = Buffer.from(process.env.JWT_PUBLIC_KEY_B64 || "", "base64").toString("utf8");

const isConfigured = () => PUBLIC_KEY.includes("BEGIN PUBLIC KEY");

// Returns { id, role, name } or null.
function verifyToken(token) {
  try {
    const c = jwt.verify(token, PUBLIC_KEY, { algorithms: ["RS256"], issuer: ISSUER, audience: AUDIENCE });
    if (typeof c.sub !== "string" || c.sub.length === 0 || c.sub.length > 64 || !ROLES.includes(c.role)) return null;
    return { id: c.sub, role: c.role, name: typeof c.name === "string" ? c.name.slice(0, 100) : "" };
  } catch {
    return null;
  }
}

module.exports = { verifyToken, isConfigured, ISSUER, AUDIENCE };
