// Lambda "club-announcements-worker": reads the SQS queue
// "club-announcements-inbox" (an event source mapping hands it up to 10
// messages at a time) and turns Events messages into announcements
// (services/fromEvents.js).
//
// Each message is handled on its own. A message that fails is reported back
// (ReportBatchItemFailures), so SQS retries only that one; after 3 failed
// tries it moves to the dead-letter queue "club-announcements-inbox-dlq".
// The rest of the batch is not repeated.
const fromEvents = require("./services/fromEvents");

function log(level, msg, extra) {
  const line = JSON.stringify({ level, msg, ...extra });
  if (level === "error") console.error(line); else console.log(line);
}

exports.handler = async (event) => {
  const batchItemFailures = [];
  for (const record of event.Records || []) {
    const id = record.messageId;
    try {
      let envelope;
      try {
        envelope = JSON.parse(record.body);
      } catch {
        throw new fromEvents.BadMessage("not JSON");
      }
      const result = await fromEvents.handle(envelope);
      log("info", "event_message", {
        messageId: id, kind: envelope["detail-type"], eventId: envelope.detail?.eventId, result,
        receiveCount: Number(record.attributes?.ApproximateReceiveCount || 1),
      });
    } catch (err) {
      // Never log the message body: only its id and what went wrong.
      log("error", "event_message_failed", {
        messageId: id, error: err instanceof fromEvents.BadMessage ? `bad_message: ${err.message}` : err.name,
        receiveCount: Number(record.attributes?.ApproximateReceiveCount || 1),
      });
      batchItemFailures.push({ itemIdentifier: id });
    }
  }
  return { batchItemFailures };
};
