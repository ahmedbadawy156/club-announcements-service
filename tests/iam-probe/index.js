// Test-only Lambda function. tests/iam.sh deploys it with the SAME IAM role
// as club-announcements-api (and again with the worker's role), runs it once
// and deletes it. It tries calls the
// role should allow and calls it should not, and reports each outcome.
const {
  DynamoDBClient, GetItemCommand, PutItemCommand, UpdateItemCommand, DeleteItemCommand,
  QueryCommand, ScanCommand, ListTablesCommand,
} = require("@aws-sdk/client-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { SQSClient, SendMessageCommand, ReceiveMessageCommand, GetQueueAttributesCommand } = require("@aws-sdk/client-sqs");
const { EventBridgeClient, PutEventsCommand } = require("@aws-sdk/client-eventbridge");

const db = new DynamoDBClient({});
const sm = new SecretsManagerClient({});
const sqs = new SQSClient({});
const eb = new EventBridgeClient({});
const queue = (name) => `${process.env.AWS_ENDPOINT_URL || "https://sqs.us-east-1.amazonaws.com"}/000000000000/${name}`;
// PutEvents reports a refused entry in the answer as well as by throwing.
const putEvents = async () => {
  const r = await eb.send(new PutEventsCommand({ Entries: [{
    EventBusName: "campus-club-bus", Source: "club.events", DetailType: "EventPublished", Detail: "{}",
  }] }));
  if (r.FailedEntryCount) { const e = new Error(r.Entries[0].ErrorCode); e.name = r.Entries[0].ErrorCode; throw e; }
};
const PROBE = { S: "iam-probe" };

async function attempt(name, fn) {
  try {
    await fn();
    return [name, "allowed"];
  } catch (e) {
    const denied = ["AccessDeniedException", "AccessDenied", "AuthorizationError", "NotAuthorizedException"];
    return [name, denied.includes(e.name) || e.Code === "AccessDenied" ? "denied" : `error:${e.name}`];
  }
}

exports.handler = async () => {
  // Writes first (in order), then the rest in parallel.
  const results = [
    await attempt("put Announcements", () => db.send(new PutItemCommand({ TableName: "Announcements", Item: { announcementId: PROBE } }))),
    await attempt("put Activities", () => db.send(new PutItemCommand({ TableName: "Activities", Item: { activityId: PROBE } }))),
  ];
  results.push(...await Promise.all([
    attempt("get Announcements", () => db.send(new GetItemCommand({ TableName: "Announcements", Key: { announcementId: PROBE } }))),
    attempt("query StatusIndex", () => db.send(new QueryCommand({
      TableName: "Announcements", IndexName: "StatusIndex", KeyConditionExpression: "#s = :p",
      ExpressionAttributeNames: { "#s": "status" }, ExpressionAttributeValues: { ":p": { S: "published" } }, Limit: 1,
    }))),
    attempt("delete Announcements", () => db.send(new DeleteItemCommand({ TableName: "Announcements", Key: { announcementId: PROBE } }))),
    attempt("scan Announcements", () => db.send(new ScanCommand({ TableName: "Announcements", Select: "COUNT" }))),
    attempt("update Activities", () => db.send(new UpdateItemCommand({
      TableName: "Activities", Key: { activityId: PROBE }, UpdateExpression: "SET summary = :t",
      ExpressionAttributeValues: { ":t": { S: "tampered" } },
    }))),
    attempt("delete Activities", () => db.send(new DeleteItemCommand({ TableName: "Activities", Key: { activityId: PROBE } }))),
    attempt("read ClubUsers", () => db.send(new GetItemCommand({ TableName: "ClubUsers", Key: { userId: PROBE } }))),
    attempt("put AuditLog", () => db.send(new PutItemCommand({ TableName: "AuditLog", Item: { logId: PROBE } }))),
    attempt("list tables", () => db.send(new ListTablesCommand({}))),
    attempt("update Announcements", () => db.send(new UpdateItemCommand({
      TableName: "Announcements", Key: { announcementId: PROBE }, UpdateExpression: "SET probe = :t",
      ExpressionAttributeValues: { ":t": { S: "x" } },
    }))),
    attempt("inbox attributes", () => sqs.send(new GetQueueAttributesCommand({ QueueUrl: queue("club-announcements-inbox"), AttributeNames: ["QueueArn"] }))),
    attempt("send to inbox", () => sqs.send(new SendMessageCommand({ QueueUrl: queue("club-announcements-inbox"), MessageBody: "{}" }))),
    // VisibilityTimeout 0: a message it happens to receive goes straight back.
    attempt("receive from DLQ", () => sqs.send(new ReceiveMessageCommand({ QueueUrl: queue("club-announcements-inbox-dlq"), VisibilityTimeout: 0 }))),
    attempt("put event on the club bus", putEvents),
    attempt("read Membership secret", () => sm.send(new GetSecretValueCommand({ SecretId: "club-membership/secrets" }))),
  ]));
  return Object.fromEntries(results);
};
