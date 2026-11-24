// Activity routes.
//   GET  /api/activities?limit=&before=   any signed-in member
//   POST /api/activities                  officer
//        { eventId, eventTitle, eventDate: "YYYY-MM-DD", summary }
const validate = require("../lib/validate");
const activities = require("../services/activities");

const FIELDS = ["eventId", "eventTitle", "eventDate", "summary"];
const MAX_AGE_YEARS = 10;

function invalid(res, fields) {
  return res.status(400).json({ error: "validation_failed", fields });
}

async function list(req, res, next) {
  try {
    const limit = validate.intParam(req.query.limit, 20, 1, 100);
    const before = req.query.before;
    const fields = [];
    if (limit === null) fields.push("limit");
    if (before !== undefined && (typeof before !== "string" || !validate.UUID_RE.test(before))) fields.push("before");
    if (fields.length) return invalid(res, fields);
    return res.status(200).json(await activities.list(limit, before));
  } catch (err) {
    if (err instanceof activities.BadCursor) return invalid(res, ["before"]);
    return next(err);
  }
}

async function create(req, res, next) {
  try {
    const b = req.body;
    if (!validate.isObject(b)) return invalid(res, ["body"]);
    const fields = validate.unknownKeys(b, FIELDS);

    const eventId = typeof b.eventId === "string" && validate.UUID_RE.test(b.eventId) ? b.eventId : null;
    if (eventId === null) fields.push("eventId");
    const eventTitle = validate.line(b.eventTitle, 3, 120);
    if (eventTitle === null) fields.push("eventTitle");
    const summary = validate.paragraph(b.summary, 10, 2000);
    if (summary === null) fields.push("summary");

    // The event must already have happened: today or earlier (UTC), and not
    // more than 10 years ago.
    const eventDate = validate.date(b.eventDate);
    const today = new Date().toISOString().slice(0, 10);
    const oldest = `${Number(today.slice(0, 4)) - MAX_AGE_YEARS}${today.slice(4)}`;
    if (eventDate === null || eventDate > today || eventDate < oldest) fields.push("eventDate");

    if (fields.length) return invalid(res, fields);

    const created = await activities.create({ eventId, eventTitle, eventDate, summary }, req.user);
    return res.status(201).json(created);
  } catch (err) {
    if (err instanceof activities.ActivityExists) return res.status(409).json({ error: "activity_exists" });
    return next(err);
  }
}

module.exports = { list, create };
