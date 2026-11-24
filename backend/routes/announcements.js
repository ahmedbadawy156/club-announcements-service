// /api/announcements
//   GET   /                 members: current feed; officers: any view
//   POST  /                 officer: publish now or at publishAt, optionally pinned
//   PATCH /:id              officer: edit, pin or unpin, reschedule, expire, archive
const express = require("express");
const controller = require("../controllers/announcements");
const { requireUser, requireOfficer } = require("../middleware/auth");

const router = express.Router();

router.get("/", requireUser, controller.list);
router.post("/", requireUser, requireOfficer, controller.create);
router.patch("/:id", requireUser, requireOfficer, controller.update);

module.exports = router;
