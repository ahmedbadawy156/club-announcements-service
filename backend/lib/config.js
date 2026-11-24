// Settings from environment variables, with the names used by infra/deploy.sh.
module.exports = {
  tables: {
    announcements: process.env.ANNOUNCEMENTS_TABLE || "Announcements",
    activities: process.env.ACTIVITIES_TABLE || "Activities",
  },
  limits: {
    maxPinned: 3, // at most 3 pinned announcements at a time
    maxScheduleDays: 365, // publishAt and expiresAt at most a year ahead
    maxListItems: 1000, // safety cap when reading a feed
  },
};
