// GET /api/health: proves the deployment runs, without touching the database.
const express = require("express");
const { isConfigured } = require("../lib/tokens");

const router = express.Router();

router.get("/", (req, res) => {
  res.status(200).json({
    service: "announcements",
    status: "ok",
    runtime: process.env.AWS_LAMBDA_FUNCTION_NAME ? "lambda" : "pc",
    tokenKey: isConfigured() ? "set" : "missing",
  });
});

module.exports = router;
