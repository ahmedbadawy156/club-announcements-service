// Authentication and roles, checked in THIS backend on every protected route.
//
// requireUser:    a valid Membership token in "Authorization: Bearer ..." or 401.
// requireOfficer: the token's role must be "officer", or 403.
//
// The user id and role come only from the verified token, never from the
// request body. Accepted risk (proposal threat 3): a demoted officer's token
// keeps its old role here until it expires (at most 15 minutes).
const { verifyToken, isConfigured } = require("../lib/tokens");

const BEARER_RE = /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*)$/;

function requireUser(req, res, next) {
  if (!isConfigured()) return next(new Error("JWT_PUBLIC_KEY_B64 is not set"));
  const match = (req.headers.authorization || "").match(BEARER_RE);
  if (!match) return res.status(401).json({ error: "sign_in_required" });
  const user = verifyToken(match[1]);
  if (!user) return res.status(401).json({ error: "invalid_token" });
  req.user = user;
  return next();
}

function requireOfficer(req, res, next) {
  if (req.user?.role !== "officer") return res.status(403).json({ error: "officer_only" });
  return next();
}

module.exports = { requireUser, requireOfficer };
