// DynamoDB client. No keys in the code: on Lambda the IAM role gives
// permission; on your PC the "floci" AWS profile does (backend/.env.example).
const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient } = require("@aws-sdk/lib-dynamodb");

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});

module.exports = { db };
