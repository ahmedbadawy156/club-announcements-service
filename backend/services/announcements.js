// Announcements: publish, schedule, pin, edit, expire and archive.
//
// Stored status is only "published" or "archived". What a reader sees is
// derived from the dates when the feed is read (no scheduler needed):
//   scheduled  published, publishAt still in the future
//   current    published, publishAt passed, not expired
//   expired    published, expiresAt passed
//   archived   taken down by an officer (kept, never hard-deleted)
//
// Business rules enforced here, inside DynamoDB conditions so they also hold
// when two officers act at the same moment:
//   - at most 3 pinned announcements: a counter item (META#pins) changes in
//     the same transaction as the pin, only while it is below 3
//   - edits need the version the officer last saw (optimistic locking), so a
//     stale edit cannot overwrite a newer one (409 version_conflict)
//   - archived announcements can no longer change
//   - publishAt can be changed only while the announcement is still scheduled
//   - expiresAt is always after publishAt
const crypto = require("crypto");
const {
  GetCommand, QueryCommand, TransactWriteCommand,
} = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");

const TABLE = config.tables.announcements;
const PIN_COUNTER_KEY = "META#pins";
const VIEWS = ["current", "scheduled", "expired", "archived"];

class NotFound extends Error {}
class Archived extends Error {}
class VersionConflict extends Error {}
class PinLimit extends Error {}
class AlreadyPublished extends Error {}
class Expired extends Error {}
class InvalidDates extends Error {
  constructor(fields) { super("invalid dates"); this.fields = fields; }
}

const DAY_MS = 24 * 60 * 60 * 1000;

function stateOf(item, nowIso) {
  if (item.status === "archived") return "archived";
  if (item.publishAt > nowIso) return "scheduled";
  if (item.expiresAt && item.expiresAt <= nowIso) return "expired";
  return "current";
}

// The fields a client may see. Internal fields (authorId, updatedBy) stay in
// the table.
function toPublic(item, nowIso, { includeVersion }) {
  const out = {
    id: item.announcementId,
    title: item.title,
    body: item.body,
    pinned: item.pinned === true,
    state: stateOf(item, nowIso),
    publishAt: item.publishAt,
    expiresAt: item.expiresAt || null,
    authorName: item.authorName,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  };
  if (includeVersion) out.version = item.version;
  return out;
}

// Checks publishAt / expiresAt against each other and the clock.
// Returns a list of bad field names (empty when fine).
function checkDates({ publishAt, expiresAt }, nowMs, { publishAtChanged }) {
  const bad = [];
  const pub = Date.parse(publishAt);
  if (publishAtChanged && (pub < nowMs - 60 * 1000 || pub > nowMs + config.limits.maxScheduleDays * DAY_MS)) {
    bad.push("publishAt");
  }
  if (expiresAt) {
    const exp = Date.parse(expiresAt);
    if (exp <= pub || exp <= nowMs || exp > pub + config.limits.maxScheduleDays * DAY_MS) bad.push("expiresAt");
  }
  return bad;
}

function pinChange(delta) {
  return delta > 0
    ? {
      Update: {
        TableName: TABLE,
        Key: { announcementId: PIN_COUNTER_KEY },
        UpdateExpression: "SET #c = if_not_exists(#c, :zero) + :one",
        ConditionExpression: "attribute_not_exists(#c) OR #c < :max",
        ExpressionAttributeNames: { "#c": "count" },
        ExpressionAttributeValues: { ":zero": 0, ":one": 1, ":max": config.limits.maxPinned },
      },
    }
    : {
      Update: {
        TableName: TABLE,
        Key: { announcementId: PIN_COUNTER_KEY },
        UpdateExpression: "SET #c = #c - :one",
        ConditionExpression: "#c > :zero",
        ExpressionAttributeNames: { "#c": "count" },
        ExpressionAttributeValues: { ":zero": 0, ":one": 1 },
      },
    };
}

function cancelledCodes(err) {
  return (err.CancellationReasons || []).map((r) => r?.Code);
}

// input: { title, body, pinned, publishAt?, expiresAt? } already validated.
async function create(input, user) {
  const now = new Date();
  const nowIso = now.toISOString();
  const publishAt = input.publishAt || nowIso;
  const bad = checkDates({ publishAt, expiresAt: input.expiresAt }, now.getTime(), { publishAtChanged: Boolean(input.publishAt) });
  if (bad.length) throw new InvalidDates(bad);

  const item = {
    announcementId: crypto.randomUUID(),
    title: input.title,
    body: input.body,
    status: "published",
    pinned: input.pinned === true,
    publishAt,
    expiresAt: input.expiresAt || undefined,
    authorId: user.id,
    authorName: user.name,
    createdAt: nowIso,
    updatedAt: nowIso,
    updatedBy: user.id,
    version: 1,
  };

  const items = [];
  if (item.pinned) items.push(pinChange(+1));
  items.push({ Put: { TableName: TABLE, Item: item, ConditionExpression: "attribute_not_exists(announcementId)" } });

  try {
    await db.send(new TransactWriteCommand({ TransactItems: items }));
  } catch (err) {
    if (err.name !== "TransactionCanceledException") throw err;
    if (item.pinned && cancelledCodes(err)[0] === "ConditionalCheckFailed") throw new PinLimit();
    throw new VersionConflict();
  }
  return toPublic(item, nowIso, { includeVersion: true });
}

async function getRaw(id) {
  const r = await db.send(new GetCommand({ TableName: TABLE, Key: { announcementId: id } }));
  return r.Item && r.Item.status ? r.Item : null; // META# items have no status
}

// patch: validated subset of { title, body, pinned, publishAt, expiresAt (null = clear), archive: true }
async function update(id, version, patch, user) {
  const current = await getRaw(id);
  if (!current) throw new NotFound();
  if (current.status === "archived") throw new Archived();
  if (current.version !== version) throw new VersionConflict();

  const now = new Date();
  const nowIso = now.toISOString();
  const state = stateOf(current, nowIso);

  const next = { ...current };
  let pinDelta = 0;

  if (patch.archive) {
    next.status = "archived";
    next.pinned = false;
    if (current.pinned) pinDelta = -1;
  } else {
    if (patch.title !== undefined) next.title = patch.title;
    if (patch.body !== undefined) next.body = patch.body;
    if (patch.publishAt !== undefined) {
      if (state !== "scheduled") throw new AlreadyPublished();
      next.publishAt = patch.publishAt;
    }
    if (patch.expiresAt !== undefined) next.expiresAt = patch.expiresAt || undefined;
    if (patch.publishAt !== undefined || patch.expiresAt !== undefined) {
      const bad = checkDates(next, now.getTime(), { publishAtChanged: patch.publishAt !== undefined });
      if (bad.length) throw new InvalidDates(bad);
    }
    if (patch.pinned !== undefined && patch.pinned !== (current.pinned === true)) {
      if (patch.pinned && stateOf(next, nowIso) === "expired") throw new Expired();
      next.pinned = patch.pinned;
      pinDelta = patch.pinned ? +1 : -1;
    }
  }

  next.version = current.version + 1;
  next.updatedAt = nowIso;
  next.updatedBy = user.id;

  const names = { "#s": "status", "#v": "version" };
  const values = { ":v": version, ":published": "published" };
  const sets = [];
  const removes = [];
  for (const field of ["title", "body", "status", "pinned", "publishAt", "expiresAt", "version", "updatedAt", "updatedBy"]) {
    if (next[field] === undefined && current[field] === undefined) continue;
    names[`#${field}`] = field;
    if (next[field] === undefined) {
      removes.push(`#${field}`);
    } else {
      values[`:${field}`] = next[field];
      sets.push(`#${field} = :${field}`);
    }
  }
  const updateItem = {
    Update: {
      TableName: TABLE,
      Key: { announcementId: id },
      UpdateExpression: `SET ${sets.join(", ")}${removes.length ? ` REMOVE ${removes.join(", ")}` : ""}`,
      ConditionExpression: "#v = :v AND #s = :published",
      ExpressionAttributeNames: names,
      ExpressionAttributeValues: values,
    },
  };

  const items = [updateItem];
  if (pinDelta !== 0) items.push(pinChange(pinDelta));

  try {
    await db.send(new TransactWriteCommand({ TransactItems: items }));
  } catch (err) {
    if (err.name !== "TransactionCanceledException") throw err;
    const codes = cancelledCodes(err);
    if (codes[0] === "ConditionalCheckFailed") {
      const latest = await getRaw(id);
      if (latest?.status === "archived") throw new Archived();
      throw new VersionConflict();
    }
    if (pinDelta > 0 && codes[1] === "ConditionalCheckFailed") throw new PinLimit();
    throw new VersionConflict(); // another write touched the same items at the same moment
  }
  return toPublic(next, nowIso, { includeVersion: true });
}

async function queryAll(params) {
  const items = [];
  let ExclusiveStartKey;
  do {
    const r = await db.send(new QueryCommand({ ...params, ExclusiveStartKey }));
    items.push(...(r.Items || []));
    ExclusiveStartKey = r.LastEvaluatedKey;
  } while (ExclusiveStartKey && items.length < config.limits.maxListItems);
  return items.slice(0, config.limits.maxListItems);
}

// view: current | scheduled | expired | archived
async function list(view, limit, { includeVersion }) {
  const nowIso = new Date().toISOString();
  const base = { TableName: TABLE, IndexName: "StatusIndex", ExpressionAttributeNames: { "#s": "status", "#p": "publishAt" } };
  let items;
  if (view === "archived") {
    items = await queryAll({
      TableName: TABLE,
      IndexName: "StatusIndex",
      KeyConditionExpression: "#s = :a",
      ExpressionAttributeNames: { "#s": "status" }, // DynamoDB refuses unused names
      ExpressionAttributeValues: { ":a": "archived" },
      ScanIndexForward: false,
    });
  } else if (view === "scheduled") {
    items = await queryAll({
      ...base, KeyConditionExpression: "#s = :p AND #p > :now", ExpressionAttributeValues: { ":p": "published", ":now": nowIso }, ScanIndexForward: true,
    });
  } else {
    items = await queryAll({
      ...base, KeyConditionExpression: "#s = :p AND #p <= :now", ExpressionAttributeValues: { ":p": "published", ":now": nowIso }, ScanIndexForward: false,
    });
    items = items.filter((it) => (view === "expired" ? stateOf(it, nowIso) === "expired" : stateOf(it, nowIso) === "current"));
    if (view === "current") {
      // Pinned first, then newest first (the query already sorted by publishAt).
      items = [...items.filter((it) => it.pinned === true), ...items.filter((it) => it.pinned !== true)];
    }
  }
  return {
    view,
    announcements: items.slice(0, limit).map((it) => toPublic(it, nowIso, { includeVersion })),
    total: items.length,
  };
}

module.exports = {
  create, update, list, VIEWS, PIN_COUNTER_KEY,
  NotFound, Archived, VersionConflict, PinLimit, AlreadyPublished, Expired, InvalidDates,
};
