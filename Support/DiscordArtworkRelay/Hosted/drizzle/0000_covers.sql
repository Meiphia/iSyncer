CREATE TABLE covers (
  id TEXT PRIMARY KEY NOT NULL,
  challenge TEXT NOT NULL UNIQUE,
  client TEXT NOT NULL,
  jpeg BLOB NOT NULL,
  expires_at INTEGER NOT NULL
);
--> statement-breakpoint
CREATE INDEX covers_expiry ON covers(expires_at);
--> statement-breakpoint
CREATE INDEX covers_client ON covers(client);
