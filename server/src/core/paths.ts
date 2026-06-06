import { fileURLToPath } from "node:url";
import { dirname, resolve, join } from "node:path";

// このファイル: <ROOT>/server/src/core/paths.ts → ROOT は 3 つ上
const here = dirname(fileURLToPath(import.meta.url));
export const ROOT = resolve(here, "../../..");

export const REGISTRY = join(ROOT, "projects", "registry.tsv");
export const BOARDS = join(ROOT, "projects", "github-projects.tsv");
export const APPS_TSV = join(ROOT, "projects", "appstore.tsv");
export const CRED_JSON = join(ROOT, "secrets", "appstore-credentials.json");
export const DASHBOARD_JSON = join(ROOT, "data", "dashboard.json");
export const STATE_JSON = join(ROOT, "data", "manager-state.json");
