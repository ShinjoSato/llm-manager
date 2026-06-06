import { readFileSync, existsSync } from "node:fs";

/** TSV を読む。「#」始まりの行と空行は無視（Python版 read_tsv 相当）。 */
export function readTsv(path: string): string[][] {
  if (!existsSync(path)) return [];
  const rows: string[][] = [];
  for (const line of readFileSync(path, "utf-8").split("\n")) {
    const l = line.replace(/\r$/, "");
    if (!l.trim() || l.trimStart().startsWith("#")) continue;
    rows.push(l.split("\t"));
  }
  return rows;
}
