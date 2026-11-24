// Input rules shared by the routes. The frontend checks the same rules for
// quick feedback, but only these server-side checks decide.

// eslint-disable-next-line no-control-regex
const CONTROL_RE = /[\u0000-\u001f\u007f]/; // no control characters at all
// eslint-disable-next-line no-control-regex
const CONTROL_EXCEPT_NEWLINE_RE = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Full date and time with a time zone, e.g. 2026-12-01T18:00:00Z or +02:00.
const DATETIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

// One-line text (titles): trimmed, length in [min, max], no control characters.
function line(v, min, max) {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length >= min && s.length <= max && !CONTROL_RE.test(s) ? s : null;
}

// Multi-line text (bodies, summaries): newlines and tabs allowed.
function paragraph(v, min, max) {
  if (typeof v !== "string") return null;
  const s = v.replace(/\r\n/g, "\n").trim();
  return s.length >= min && s.length <= max && !CONTROL_EXCEPT_NEWLINE_RE.test(s) ? s : null;
}

// ISO date-time with a time zone -> "YYYY-MM-DDTHH:mm:ss.sssZ" (UTC), or null.
function dateTime(v) {
  if (typeof v !== "string" || !DATETIME_RE.test(v)) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

// Calendar date "YYYY-MM-DD" that really exists (no 2026-02-30), or null.
function date(v) {
  if (typeof v !== "string" || !DATE_RE.test(v)) return null;
  const d = new Date(`${v}T00:00:00.000Z`);
  return Number.isFinite(d.getTime()) && d.toISOString().slice(0, 10) === v ? v : null;
}

// Keys in obj that are not in allowed.
const unknownKeys = (obj, allowed) => Object.keys(obj).filter((k) => !allowed.includes(k));

// Whole-number query parameter within [min, max]; null if invalid.
function intParam(value, fallback, min, max) {
  if (value === undefined) return fallback;
  if (typeof value !== "string" || !/^\d{1,6}$/.test(value)) return null;
  const n = Number(value);
  return n >= min && n <= max ? n : null;
}

module.exports = {
  isObject, line, paragraph, dateTime, date, unknownKeys, intParam, UUID_RE, CONTROL_RE,
};
