# DynamoDB tables (Announcements and Club Activity)

`infra/deploy.sh` creates each table from its JSON file if it is missing.

## Announcements

| Attribute | Notes |
|---|---|
| `announcementId` (key) | UUID, or `META#pins` for the pinned counter |
| `title`, `body` | Plain text, shown with `textContent` in the frontend |
| `status` | `published` or `archived` (stored). `scheduled`, `current` and `expired` are worked out from the dates when the feed is read |
| `pinned` | Boolean; at most 3 at a time, enforced by the `META#pins` counter in the same transaction |
| `publishAt`, `expiresAt` | ISO 8601 UTC. `expiresAt` is optional and always after `publishAt` |
| `authorId`, `authorName`, `updatedBy` | From the verified token (`sub`, `name`), never from the body |
| `createdAt`, `updatedAt`, `version` | `version` goes up on every edit (optimistic locking) |

`StatusIndex` (`status`, `publishAt`) serves every feed: current and expired
(`publishAt <= now`), scheduled (`publishAt > now`) and archived. The counter
item has no `status`, so it never appears in the index.

## Activities

| Attribute | Notes |
|---|---|
| `activityId` (key) | UUID, or `EVENT#<eventId>` for the one-activity-per-event claim |
| `eventId`, `eventTitle`, `eventDate` | The event in the Events service; date `YYYY-MM-DD`, not in the future |
| `summary` | Plain text |
| `recordedBy`, `recordedByName` | From the verified token |
| `feed`, `sortKey` | `ACTIVITY` and `eventDate#createdAt#activityId` for `FeedIndex` |

`FeedIndex` (`feed`, `sortKey`) lists activities newest event first, with a
`before` cursor. Claim items have no `feed`, so they never appear in it.
