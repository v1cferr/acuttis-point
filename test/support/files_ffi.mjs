import { mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export function size(path) {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

export function remove(path) {
  rmSync(path, { force: true, recursive: true });
}

export function write(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
}
