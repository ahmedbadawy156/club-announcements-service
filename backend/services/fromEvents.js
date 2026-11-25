// Announcements written automatically from the Events service's messages.
//
// Path: Events -> EventBridge bus "campus-club-bus" -> rule
// "club-events-to-announcements" -> SQS queue "club-announcements-inbox" ->
// worker.js (Lambda "club-announcements-worker") -> here.
//
//   EventPublished  -> "New event: <title>"   (expires when the event starts)
//   EventCancelled  -> "Cancelled: <title>"   (expires when the event would
//                      have started), and the "New event" post is archived
//
// SQS may deliver a message more than once, and not always in order, so:
//   - the announcement id comes from the event id and the message kind, and
//     a second delivery finds the item already there and changes nothing
//   - a "New event" post is never left up once the cancellation is in
const crypto = require("crypto");
const { GetCommand, PutCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");
const validate = require("../lib/validate");
const announcements = require("./announcements");

const TABLE = config.tables.announcements;
const SOURCE = "club.events";
const AUTHOR_NAME = "Club Events (automatic)";

// A message that can never be processed. The worker reports it as failed, so
// after 3 tries SQS moves it to the dead-letter queue for an officer to look at.
class BadMessage extends Error {}

// Same event + same kind -> same UUID-shaped id, every time.
function idFor(kind, eventId) {
  const h = crypto.createHash("sha256").update(`${kind}:${eventId}`).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

function when(iso) {
  const d = new Date(iso);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const hh = String(d.getUTCHours()).padStart(2, "0");
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${d.getUTCDate()} ${months[d.getUTCMonth()]} ${d.getUTCFullYear()}, ${hh}:${mm} UTC`;
}

const clip = (s, n) => (s.length <= n ? s : `${s.slice(0, n - 1)}…`);

// Checks an EventBridge envelope's detail; returns it cleaned, or throws BadMessage.
function readDetail(envelope) {
  const d = envelope.detail;
  if (!validate.isObject(d)) throw new BadMessage("no detail");
  const eventId = typeof d.eventId === "string" ? d.eventId.toLowerCase() : "";
  const title = validate.line(d.title, 1, 120);
  const location = validate.line(d.location, 1, 200);
  const startsAt = validate.dateTime(d.startsAt);
  const by = typeof d.by === "string" && validate.UUID_RE.test(d.by) ? d.by.toLowerCase() : null;
  if (!validate.UUID_RE.test(eventId) || !title || !location || !startsAt || !by) throw new BadMessage("invalid detail");
  return { eventId, title, location, startsAt, by };
}

const exists = async (id) => Boolean((await db.send(new GetCommand({ TableName: TABLE, Key: { announcementId: id } }))).Item);

async function putOnce(item) {
  try {
    await db.send(new PutCommand({ TableName: TABLE, Item: item, ConditionExpression: "attribute_not_exists(announcementId)" }));
    return "created";
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") return "duplicate";
    throw err;
  }
}

function baseItem(kind, d, title, body, nowIso) {
  return {
    announcementId: idFor(kind, d.eventId),
    title: clip(title, 120),
    body: clip(body, 2000),
    status: "published",
    pinned: false,
    publishAt: nowIso,
    expiresAt: d.startsAt,
    authorId: d.by, // the officer whose action caused it
    authorName: AUTHOR_NAME,
    origin: "events",
    eventId: d.eventId,
    createdAt: nowIso,
    updatedAt: nowIso,
    updatedBy: d.by,
    version: 1,
  };
}

// Archive the "New event" post of this event, if it is still up.
async function archiveNewEventPost(d) {
  const postId = idFor("published", d.eventId);
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const r = await db.send(new GetCommand({ TableName: TABLE, Key: { announcementId: postId } }));
    if (!r.Item || r.Item.status !== "published") return;
    try {
      // announcements.update keeps the pin counter right if an officer had
      // pinned the post. Retry once if an officer edited it at that moment.
      await announcements.update(postId, r.Item.version, { archive: true }, { id: d.by });
      return;
    } catch (err) {
      if (!(err instanceof announcements.VersionConflict) && !(err instanceof announcements.Archived)) throw err;
    }
  }
}

async function onPublished(d, nowIso) {
  if (d.startsAt <= nowIso) return "skipped_started";
  // The cancellation arrived first: the event is already over for members.
  if (await exists(idFor("cancelled", d.eventId))) return "skipped_cancelled";
  const result = await putOnce(baseItem("published", d, `New event: ${d.title}`,
    `${d.title} takes place on ${when(d.startsAt)} at ${d.location}.\nRSVP on the Events page while seats are left.`, nowIso));
  // Both messages were handled at the same moment: look once more.
  if (await exists(idFor("cancelled", d.eventId))) await archiveNewEventPost(d);
  return result;
}

async function onCancelled(d, nowIso) {
  if (d.startsAt <= nowIso) return "skipped_started";
  const result = await putOnce(baseItem("cancelled", d, `Cancelled: ${d.title}`,
    `${d.title} on ${when(d.startsAt)} at ${d.location} has been cancelled.\nEveryone with an RSVP has been notified.`, nowIso));
  await archiveNewEventPost(d);
  return result;
}

// One EventBridge envelope (the SQS message body, parsed). Returns what
// happened: created | duplicate | skipped_started | skipped_cancelled | ignored.
async function handle(envelope) {
  if (!validate.isObject(envelope) || envelope.source !== SOURCE) throw new BadMessage("unexpected source");
  const kind = envelope["detail-type"];
  if (kind !== "EventPublished" && kind !== "EventCancelled") return "ignored"; // a kind we do not post about
  const d = readDetail(envelope);
  const nowIso = new Date().toISOString();
  return kind === "EventPublished" ? onPublished(d, nowIso) : onCancelled(d, nowIso);
}

module.exports = { handle, idFor, BadMessage };
