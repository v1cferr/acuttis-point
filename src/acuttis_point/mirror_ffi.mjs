// SQLite comes from node itself, so this adds no dependency — which matters for
// a flake that pins every one of them.
//
// It is still an experimental module, so it is required lazily rather than
// imported: only a run that actually mirrors pays the warning on stderr, and a
// node that one day drops it breaks the audit's last step instead of every run.
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

const require = createRequire(import.meta.url);

// Dates are YYYY-MM-DD and times HH:MM, so lexicographic order is chronological
// order and the queries a human writes by hand do the obvious thing.
const SCHEMA = `
  CREATE TABLE IF NOT EXISTS marking (
    date TEXT NOT NULL,
    time TEXT NOT NULL,
    PRIMARY KEY (date, time)
  ) WITHOUT ROWID;

  CREATE TABLE IF NOT EXISTS mirrored (
    at       TEXT NOT NULL,
    oldest   TEXT NOT NULL,
    newest   TEXT NOT NULL,
    days     INTEGER NOT NULL,
    markings INTEGER NOT NULL
  );
`;

export function replaceDays(path, days, at) {
  let db;
  try {
    const { DatabaseSync } = require("node:sqlite");
    mkdirSync(dirname(path), { recursive: true });

    db = new DatabaseSync(path);
    db.exec(SCHEMA);

    const forget = db.prepare("DELETE FROM marking WHERE date = ?");
    const remember = db.prepare(
      "INSERT INTO marking (date, time) VALUES (?, ?)",
    );
    const noted = db.prepare(
      "INSERT INTO mirrored (at, oldest, newest, days, markings)" +
        " VALUES (?, ?, ?, ?, ?)",
    );

    const rows = days.toArray().map((day) => [day[0], day[1].toArray()]);
    let markings = 0;
    let oldest = null;
    let newest = null;

    // One transaction over the whole receipt. A day half written is a day that
    // reads as short, and a short day is the exact shape of a forgotten punch —
    // so the mirror must never be able to invent one by being interrupted.
    db.exec("BEGIN");
    try {
      for (const [date, times] of rows) {
        forget.run(date);
        for (const time of times) {
          remember.run(date, time);
          markings += 1;
        }
        if (oldest === null || date < oldest) oldest = date;
        if (newest === null || date > newest) newest = date;
      }
      if (rows.length > 0) {
        noted.run(at, oldest, newest, rows.length, markings);
      }
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }

    return "";
  } catch (error) {
    return error.message ?? String(error);
  } finally {
    try {
      db?.close();
    } catch {
      // Nothing useful to do about a close that fails, and the write is done.
    }
  }
}
