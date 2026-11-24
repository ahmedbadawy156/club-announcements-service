// Test-only helpers with the local Floci admin keys ("floci" profile).
//   node tests/helpers.js token USERID ROLE [valid|expired|wrongkey|none|hs256|tampered|wrongaud|wrongiss]
//   node tests/helpers.js cleanup          delete everything written by the test users
//   node tests/helpers.js set ID FIELD JSON  change one field of an announcement (to move dates into the past)
//   node tests/helpers.js get ID           print one announcement item
//   node tests/helpers.js pins             print the pinned counter
//
// Tokens are signed with Membership's real private key, read from Secrets
// Manager on the LOCAL Floci, only so tests can build valid and attack
// tokens without creating accounts. The deployed function never sees it.
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

process.env.AWS_PROFILE ||= "floci";
process.env.AWS_REGION ||= "us-east-1";
process.env.AWS_ENDPOINT_URL ||= "http://localhost:4566";

const req = (m) => require(path.join(__dirname, "..", "backend", "node_modules", m));
const { DynamoDBClient } = req("@aws-sdk/client-dynamodb");
const {
  DynamoDBDocumentClient, ScanCommand, DeleteCommand, PutCommand, GetCommand, UpdateCommand,
} = req("@aws-sdk/lib-dynamodb");
const jwt = req("jsonwebtoken");

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
// Test users all have ids starting with this prefix (see tests/lib.sh).
const TEST_PREFIX = "aaaaaaaa-0000-4000-8000-";

async function scanAll(TableName) {
  const items = [];
  let ExclusiveStartKey;
  do {
    const r = await db.send(new ScanCommand({ TableName, ExclusiveStartKey }));
    items.push(...(r.Items || []));
    ExclusiveStartKey = r.LastEvaluatedKey;
  } while (ExclusiveStartKey);
  return items;
}

async function recountPins() {
  const items = await scanAll("Announcements");
  const count = items.filter((a) => a.status === "published" && a.pinned === true).length;
  await db.send(new PutCommand({ TableName: "Announcements", Item: { announcementId: "META#pins", count } }));
  return count;
}

async function cleanup() {
  let removed = 0;
  for (const a of await scanAll("Announcements")) {
    if ((a.authorId || "").startsWith(TEST_PREFIX)) {
      await db.send(new DeleteCommand({ TableName: "Announcements", Key: { announcementId: a.announcementId } }));
      removed += 1;
    }
  }
  const activities = await scanAll("Activities");
  const testIds = new Set(activities.filter((a) => (a.recordedBy || "").startsWith(TEST_PREFIX)).map((a) => a.activityId));
  for (const a of activities) {
    if (testIds.has(a.activityId) || testIds.has(a.activityRef)) {
      await db.send(new DeleteCommand({ TableName: "Activities", Key: { activityId: a.activityId } }));
      removed += 1;
    }
  }
  const pins = await recountPins();
  console.log(`removed ${removed} test items; pinned now ${pins}`);
}

function membershipSecret() {
  const aws = process.env.AWS_BIN || "aws";
  const out = execFileSync(aws, ["secretsmanager", "get-secret-value", "--secret-id", "club-membership/secrets",
    "--query", "SecretString", "--output", "text"], { encoding: "utf8" });
  return JSON.parse(out);
}

function token(userId, role, variant = "valid") {
  const s = membershipSecret();
  const claims = { role, name: role === "officer" ? "Test Officer" : "Test Member" };
  const opts = { subject: userId, issuer: "club-membership", audience: "campus-club" };
  const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const body = { ...claims, sub: userId, iss: opts.issuer, aud: opts.audience, iat: now, exp: now + 900 };
  switch (variant) {
    case "valid": return jwt.sign(claims, s.jwtPrivateKey, { ...opts, algorithm: "RS256", expiresIn: 900 });
    case "expired": return jwt.sign({ ...claims, exp: now - 60 }, s.jwtPrivateKey, { ...opts, algorithm: "RS256" });
    case "wrongaud": return jwt.sign(claims, s.jwtPrivateKey, { ...opts, audience: "other-app", algorithm: "RS256", expiresIn: 900 });
    case "wrongiss": return jwt.sign(claims, s.jwtPrivateKey, { ...opts, issuer: "someone-else", algorithm: "RS256", expiresIn: 900 });
    case "wrongkey": {
      const { privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
      return jwt.sign(claims, privateKey, { ...opts, algorithm: "RS256", expiresIn: 900 });
    }
    case "none": return `${b({ alg: "none", typ: "JWT" })}.${b(body)}.`;
    case "hs256": {
      // Classic attack: sign with HS256 using the PUBLIC key as the secret.
      const head = `${b({ alg: "HS256", typ: "JWT" })}.${b(body)}`;
      return `${head}.${crypto.createHmac("sha256", s.jwtPublicKey).update(head).digest("base64url")}`;
    }
    case "tampered": {
      // A real member token whose payload is edited to say officer.
      const [h, , sig] = jwt.sign(claims, s.jwtPrivateKey, { ...opts, algorithm: "RS256", expiresIn: 900 }).split(".");
      return `${h}.${b({ ...body, role: "officer" })}.${sig}`;
    }
    default: throw new Error(`unknown variant ${variant}`);
  }
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case "token": process.stdout.write(token(args[0], args[1], args[2])); break;
    case "cleanup": await cleanup(); break;
    case "set":
      await db.send(new UpdateCommand({
        TableName: "Announcements",
        Key: { announcementId: args[0] },
        UpdateExpression: "SET #f = :v",
        ExpressionAttributeNames: { "#f": args[1] },
        ExpressionAttributeValues: { ":v": JSON.parse(args[2]) },
      }));
      break;
    case "get": {
      const r = await db.send(new GetCommand({ TableName: "Announcements", Key: { announcementId: args[0] } }));
      process.stdout.write(JSON.stringify(r.Item || null));
      break;
    }
    case "pins": {
      const r = await db.send(new GetCommand({ TableName: "Announcements", Key: { announcementId: "META#pins" } }));
      process.stdout.write(String(r.Item?.count ?? 0));
      break;
    }
    default:
      console.error("usage: node tests/helpers.js token|cleanup|set|get|pins ...");
      process.exit(2);
  }
}

main().catch((err) => { console.error(err.name, err.message); process.exit(1); });
