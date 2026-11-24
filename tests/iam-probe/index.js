// Test-only Lambda function. tests/iam.sh deploys it with the SAME IAM role
// as club-announcements-api, runs it once and deletes it. It tries calls the
// role should allow and calls it should not, and reports each outcome.
const {
  DynamoDBClient, GetItemCommand, PutItemCommand, UpdateItemCommand, DeleteItemCommand,
  QueryCommand, ScanCommand, ListTablesCommand,
} = require("@aws-sdk/client-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");

const db = new DynamoDBClient({});
const sm = new SecretsManagerClient({});
const PROBE = { S: "iam-probe" };

async function attempt(name, fn) {
  try {
    await fn();
    return [name, "allowed"];
  } catch (e) {
    return [name, e.name === "AccessDeniedException" ? "denied" : `error:${e.name}`];
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
    attempt("read Membership secret", () => sm.send(new GetSecretValueCommand({ SecretId: "club-membership/secrets" }))),
  ]));
  return Object.fromEntries(results);
};
