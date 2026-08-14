import { rmSync } from "node:fs";

export function remove(path) {
  rmSync(path, { force: true });
  return undefined;
}
