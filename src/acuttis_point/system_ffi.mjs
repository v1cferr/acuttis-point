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

// Two shapes, because ntfy takes an attachment as the request *body*:
//   no file  → JSON body
//   a file   → the bytes as body, and the message moves into headers
//
// `action` is a label and a command, published to `commandUrl` when the button
// is tapped. That is the whole remote control: the phone posts to a topic this
// machine is listening on, so nothing here has to accept an inbound connection.
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

  // clear=true dismisses the notification once the button is tapped, so a
  // notification still sitting there means it has not been acted on.
  const actions =
    actionLabel && actionCommand && commandUrl
      ? [
          {
            action: "http",
            label: actionLabel,
            url: commandUrl,
            method: "POST",
            body: actionCommand,
            clear: true,
          },
        ]
      : [];

  try {
    const request = attachment
      ? {
          method: "PUT",
          headers: {
            Title: utf8Header(title),
            Message: utf8Header(body),
            Priority: String(level),
            Tags: tags,
            Filename: basename(attachment),
            ...(actions.length
              ? {
                  Actions: utf8Header(
                    `http, ${actionLabel}, ${commandUrl}, method=POST, body=${actionCommand}, clear=true`,
                  ),
                }
              : {}),
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
            ...(actions.length ? { actions } : {}),
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
