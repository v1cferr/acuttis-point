import { existsSync, rmSync } from "node:fs";

export function remove(path) {
  rmSync(path, { force: true });
  return undefined;
}

export function exists(path) {
  return existsSync(path);
}
