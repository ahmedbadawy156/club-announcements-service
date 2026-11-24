// Past club activities: what happened at a finished event.
//
// Business rules:
//   - only for an event that has already happened (eventDate not in the future)
//   - one activity per event: a claim item "EVENT#<eventId>" is written in
//     the same transaction, only if it does not exist yet, so two officers
//     recording the same event at the same moment cannot both succeed (409)
//   - activities are a record: there is no edit or delete route
//
// The event id is not checked against the Events service, because services
// do not call each other (proposal Section 5.3, accepted limitation). The
// officer types or pastes the event's id, title and date.
const crypto = require("crypto");
const { GetCommand, QueryCommand, TransactWriteCommand } = require("@aws-sdk/lib-dynamodb");
const { db } = require("../lib/aws");
const config = require("../lib/config");

const TABLE = config.tables.activities;
const FEED = "ACTIVITY";

class ActivityExists extends Error {}
class BadCursor extends Error {}

function toPublic(item) {
  return {
    id: item.activityId,
    eventId: item.eventId,
    eventTitle: item.eventTitle,
    eventDate: item.eventDate,
    summary: item.summary,
    recordedByName: item.recordedByName,
    createdAt: item.createdAt,
  };
}

// input: { eventId, eventTitle, eventDate, summary } already validated.
async function create(input, user) {
  const nowIso = new Date().toISOString();
  const activityId = crypto.randomUUID();
  const item = {
    activityId,
    eventId: input.eventId.toLowerCase(),
    eventTitle: input.eventTitle,
    eventDate: input.eventDate,
    summary: input.summary,
    recordedBy: user.id,
    recordedByName: user.name,
    createdAt: nowIso,
    feed: FEED,
    // Newest event first; ties broken by creation time and id.
    sortKey: `${input.eventDate}#${nowIso}#${activityId}`,
  };
  try {
    await db.send(new TransactWriteCommand({
      TransactItems: [
        {
          Put: {
            TableName: TABLE,
            Item: { activityId: `EVENT#${item.eventId}`, activityRef: activityId, createdAt: nowIso },
            ConditionExpression: "attribute_not_exists(activityId)",
          },
        },
        { Put: { TableName: TABLE, Item: item, ConditionExpression: "attribute_not_exists(activityId)" } },
      ],
    }));
  } catch (err) {
    if (err.name === "TransactionCanceledException") throw new ActivityExists();
    throw err;
  }
  return toPublic(item);
}

// Newest event first, `limit` at a time. `before` is the id of the last
// activity of the previous page.
async function list(limit, before) {
  const params = {
    TableName: TABLE,
    IndexName: "FeedIndex",
    KeyConditionExpression: "feed = :f",
    ExpressionAttributeValues: { ":f": FEED },
    ScanIndexForward: false,
    Limit: limit + 1,
  };
  if (before) {
    const r = await db.send(new GetCommand({ TableName: TABLE, Key: { activityId: before } }));
    if (!r.Item || r.Item.feed !== FEED) throw new BadCursor();
    params.KeyConditionExpression = "feed = :f AND sortKey < :sk";
    params.ExpressionAttributeValues[":sk"] = r.Item.sortKey;
  }
  const r = await db.send(new QueryCommand(params));
  const items = r.Items || [];
  const page = items.slice(0, limit);
  return {
    activities: page.map(toPublic),
    nextBefore: items.length > limit ? page[page.length - 1].activityId : null,
  };
}

module.exports = { create, list, ActivityExists, BadCursor };
