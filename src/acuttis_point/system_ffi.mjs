import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { basename, dirname } from "node:path";

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

// HTTP headers are ASCII. Everything this project puts in a title is already
// English, but a failure detail can carry page text in any language, so the
// header path is transliterated rather than trusted.
const asciiOnly = (value) =>
  value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^\x20-\x7e]/g, "?");

// Two shapes, because ntfy takes an attachment as the request *body*:
//   no file  → JSON body, so the message survives any alphabet
//   a file   → the bytes as body, and the message moves into headers
export async function postNotification(
  url,
  title,
  body,
  priority,
  tags,
  attachment,
) {
  const levels = { min: 1, low: 2, default: 3, high: 4, urgent: 5 };
  const level = levels[priority] ?? 3;

  try {
    const request = attachment
      ? {
          method: "PUT",
          headers: {
            Title: asciiOnly(title),
            Message: asciiOnly(body),
            Priority: String(level),
            Tags: tags,
            Filename: basename(attachment),
          },
          body: readFileSync(attachment),
        }
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            title,
            message: body,
            priority: level,
            tags: tags ? tags.split(",") : [],
          }),
        };

    const response = await fetch(url, {
      ...request,
      // A run must not hang on a notification service being slow.
      signal: AbortSignal.timeout(20_000),
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
