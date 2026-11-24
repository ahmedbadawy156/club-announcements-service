// Announcement routes.
//   GET   /api/announcements?view=&limit=   members: view=current only; officers: any view
//   POST  /api/announcements                officer
//         { title, body, pinned?, publishAt?, expiresAt? }
//   PATCH /api/announcements/:id            officer
//         { version, title?, body?, pinned?, publishAt?, expiresAt? (null clears) }
//         or { version, status: "archived" }
const validate = require("../lib/validate");
const announcements = require("../services/announcements");

const TITLE = [3, 120];
const BODY = [1, 2000];
const CREATE_FIELDS = ["title", "body", "pinned", "publishAt", "expiresAt"];
const UPDATE_FIELDS = ["version", "title", "body", "pinned", "publishAt", "expiresAt", "status"];

function invalid(res, fields) {
  return res.status(400).json({ error: "validation_failed", fields });
}

function handleError(err, res, next) {
  if (err instanceof announcements.InvalidDates) return invalid(res, err.fields);
  if (err instanceof announcements.NotFound) return res.status(404).json({ error: "announcement_not_found" });
  if (err instanceof announcements.Archived) return res.status(409).json({ error: "announcement_archived" });
  if (err instanceof announcements.VersionConflict) return res.status(409).json({ error: "version_conflict" });
  if (err instanceof announcements.PinLimit) return res.status(409).json({ error: "pin_limit_reached", maxPinned: 3 });
  if (err instanceof announcements.AlreadyPublished) return res.status(409).json({ error: "already_published" });
  if (err instanceof announcements.Expired) return res.status(409).json({ error: "announcement_expired" });
  return next(err);
}

async function list(req, res, next) {
  try {
    const view = req.query.view ?? "current";
    const limit = validate.intParam(req.query.limit, 50, 1, 100);
    const fields = [];
    if (!announcements.VIEWS.includes(view)) fields.push("view");
    if (limit === null) fields.push("limit");
    if (fields.length) return invalid(res, fields);

    const officer = req.user.role === "officer";
    // Members see only what is live now; scheduled, expired and archived
    // announcements are for officers.
    if (view !== "current" && !officer) return res.status(403).json({ error: "officer_only" });

    return res.status(200).json(await announcements.list(view, limit, { includeVersion: officer }));
  } catch (err) {
    return next(err);
  }
}

async function create(req, res, next) {
  try {
    const b = req.body;
    if (!validate.isObject(b)) return invalid(res, ["body"]);
    const fields = validate.unknownKeys(b, CREATE_FIELDS);
    const title = validate.line(b.title, ...TITLE);
    if (title === null) fields.push("title");
    const text = validate.paragraph(b.body, ...BODY);
    if (text === null) fields.push("body");
    if (b.pinned !== undefined && typeof b.pinned !== "boolean") fields.push("pinned");
    const publishAt = b.publishAt === undefined ? undefined : validate.dateTime(b.publishAt);
    if (publishAt === null) fields.push("publishAt");
    const expiresAt = b.expiresAt === undefined || b.expiresAt === null ? undefined : validate.dateTime(b.expiresAt);
    if (expiresAt === null) fields.push("expiresAt");
    if (fields.length) return invalid(res, fields);

    const created = await announcements.create({
      title, body: text, pinned: b.pinned === true, publishAt, expiresAt,
    }, req.user);
    return res.status(201).json(created);
  } catch (err) {
    return handleError(err, res, next);
  }
}

async function update(req, res, next) {
  try {
    const { id } = req.params;
    if (!validate.UUID_RE.test(id)) return invalid(res, ["id"]);
    const b = req.body;
    if (!validate.isObject(b)) return invalid(res, ["body"]);

    const fields = validate.unknownKeys(b, UPDATE_FIELDS);
    if (!Number.isInteger(b.version) || b.version < 1) fields.push("version");
    const patch = {};

    if (b.status !== undefined) {
      // Archiving is its own action: no other changes in the same request.
      if (b.status !== "archived") fields.push("status");
      const others = Object.keys(b).filter((k) => k !== "status" && k !== "version");
      if (others.length) fields.push(...others);
      patch.archive = true;
    } else {
      if (b.title !== undefined) {
        patch.title = validate.line(b.title, ...TITLE);
        if (patch.title === null) fields.push("title");
      }
      if (b.body !== undefined) {
        patch.body = validate.paragraph(b.body, ...BODY);
        if (patch.body === null) fields.push("body");
      }
      if (b.pinned !== undefined) {
        if (typeof b.pinned !== "boolean") fields.push("pinned");
        patch.pinned = b.pinned;
      }
      if (b.publishAt !== undefined) {
        patch.publishAt = validate.dateTime(b.publishAt);
        if (patch.publishAt === null) fields.push("publishAt");
      }
      if (b.expiresAt !== undefined) {
        patch.expiresAt = b.expiresAt === null ? null : validate.dateTime(b.expiresAt);
        if (b.expiresAt !== null && patch.expiresAt === null) fields.push("expiresAt");
      }
      if (Object.keys(patch).length === 0 && fields.length === 0) fields.push("changes");
    }
    if (fields.length) return invalid(res, [...new Set(fields)]);

    return res.status(200).json(await announcements.update(id, b.version, patch, req.user));
  } catch (err) {
    return handleError(err, res, next);
  }
}

module.exports = { list, create, update };
