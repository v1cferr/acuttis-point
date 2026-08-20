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

// Node's fetch writes a header value as ISO-8859-1, one byte per character, so
// a JS string with accents in it arrives mangled. Encoding to UTF-8 first and
// re-reading those bytes as latin1 makes the header carry exactly the UTF-8
// sequence ntfy decodes. Verified against ntfy.sh both ways: without this,
// "saída" arrives as "sa\ufffdda"; with it, it arrives as itself.
//
// This replaced stripping the accents, which was a worse answer to a problem I
// had guessed at rather than measured.
const utf8Header = (value) => Buffer.from(value, "utf8").toString("latin1");

// One shape: metadata in headers, the body is the payload.
//
// It used to be two, and the other one was silently wrong. A JSON body is only
// read as JSON by ntfy when it is posted to the root endpoint with the topic
// inside it; posted to https://ntfy.sh/<topic> the body is the message text. So
// every notification without an attachment arrived with no title, no priority
// and the raw JSON as its text — including the punch confirmations, which are
// the one message whose job is to stop a second punch being made by hand. On
// 2026-08-20 the 07:59 confirmation went out looking like that, was
// indistinguishable from noise, and a duplicate landed at 08:08.
//
// Headers for everything, then, and the body carries the message or the file.
// Verified against ntfy.sh both ways before changing it.
export async function postNotification(
  url,
  title,
  body,
  priority,
  tags,
  attachment,
  actionLabel,
  actionCommand,
  commandUrl,
) {
  const levels = { min: 1, low: 2, default: 3, high: 4, urgent: 5 };
  const level = levels[priority] ?? 3;

  const headers = {
    Title: utf8Header(title),
    Priority: String(level),
    Tags: tags,
  };

  // clear=true dismisses the notification once the button is tapped, so one
  // still sitting there means it has not been acted on.
  if (actionLabel && actionCommand && commandUrl) {
    headers.Actions = utf8Header(
      `http, ${actionLabel}, ${commandUrl}, method=POST, body=${actionCommand}, clear=true`,
    );
  }

  let payload;
  if (attachment) {
    // The bytes are the body, so the text has to travel in a header.
    headers.Message = utf8Header(body);
    headers.Filename = basename(attachment);
    payload = readFileSync(attachment);
  } else {
    // Raw UTF-8, which is what ntfy reads a plain body as. Newlines survive,
    // which is why a list of dates can be a list of lines.
    payload = Buffer.from(body, "utf8");
  }

  try {
    const response = await fetch(url, {
      method: attachment ? "PUT" : "POST",
      headers,
      body: payload,
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
