import { rmSync, statSync } from "node:fs";

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
