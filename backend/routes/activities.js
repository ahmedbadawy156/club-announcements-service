// /api/activities
//   GET  /     any signed-in member: past activities, newest event first
//   POST /     officer: record what happened at a finished event
const express = require("express");
const controller = require("../controllers/activities");
const { requireUser, requireOfficer } = require("../middleware/auth");

const router = express.Router();

router.get("/", requireUser, controller.list);
router.post("/", requireUser, requireOfficer, controller.create);

module.exports = router;
