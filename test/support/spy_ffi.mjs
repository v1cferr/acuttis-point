export function newCell(value) {
  return { value };
}

export function getCell(cell) {
  return cell.value;
}

export function setCell(cell, value) {
  cell.value = value;
  return undefined;
}
