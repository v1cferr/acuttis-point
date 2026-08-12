import { appendFileSync, mkdirSync } from "node:fs";
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

export function appendToFile(path, text) {
  try {
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, text, "utf8");
    return "";
  } catch (error) {
    return error.message ?? String(error);
  }
}

export function setExitStatus(status) {
  process.exitCode = status;
  return undefined;
}
