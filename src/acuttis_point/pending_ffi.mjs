import { randomBytes } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

// Base32 without padding: short enough to read out loud over the phone, and no
// characters that a URL or an ntfy action body would need escaped.
const ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789";

export function freshToken() {
  return Array.from(randomBytes(10))
    .map((byte) => ALPHABET[byte % ALPHABET.length])
    .join("");
}

export function writeFile(path, text) {
  try {
    mkdirSync(dirname(path), { recursive: true });
    // 0600: whoever can read this can spend it.
    writeFileSync(path, text, { mode: 0o600 });
    return "";
  } catch (error) {
    return error.message ?? String(error);
  }
}

export function readFile(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

// The whole point of this module, in one call. rename(2) is atomic within a
// filesystem: exactly one caller can move a given file, so two runs racing for
// the same punch cannot both win. Losing looks the same as there being nothing
// to claim, which is the right answer for the loser either way.
export function claimFile(from, to) {
  try {
    renameSync(from, to);
    return "";
  } catch (error) {
    return error.code === "ENOENT" ? "missing" : (error.message ?? String(error));
  }
}

export function removeFile(path) {
  rmSync(path, { force: true });
  return undefined;
}
