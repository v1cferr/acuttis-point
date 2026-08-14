import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

// A Gleam tuple is a JavaScript array, so `Object.entries` already has the
// shape of `Array(#(String, String))`.
export function environmentEntries() {
  return Object.entries(process.env).filter(
    ([, value]) => typeof value === "string",
  );
}

// `hourCycle: "h23"` rather than `hour12: false`: the latter reports midnight
// as hour 24 on some runtimes, which is not a time of day Gleam accepts.
export function clockParts(timeZone) {
  let parts;
  try {
    parts = new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date());
  } catch {
    // An unrecognised zone throws a RangeError. Reporting no parts lets Gleam
    // turn that into UnknownTimezone.
    return [];
  }

  const found = {};
  for (const { type, value } of parts) {
    found[type] = value;
  }

  return [
    Number(found.year),
    Number(found.month),
    Number(found.day),
    Number(found.hour),
    Number(found.minute),
  ];
}

// A missing or unreadable .env is the normal case in production, so it reads as
// "nothing to add" rather than as a failure.
export function readFileOrEmpty(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

export function appendToFile(path, text) {
  try {
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, text, "utf8");
    return "";
  } catch (error) {
    return error.message ?? String(error);
  }
}

// ntfy reads the title, priority and tags off headers and takes the body as the
// message. Header values have to stay ASCII, which the notification module's
// fixed titles and tags already are.
export async function postNotification(url, title, body, priority, tags) {
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: { Title: title, Priority: priority, Tags: tags },
      body,
      // A run must not hang on a notification service being slow.
      signal: AbortSignal.timeout(10_000),
    });
    return response.ok ? "" : `answered ${response.status}`;
  } catch (error) {
    return error.message ?? String(error);
  }
}

export function setExitStatus(status) {
  process.exitCode = status;
  return undefined;
}
