// ai-manager ドメイン型。server（取得・API）と web（React）で共有する。
// データ実体は projects/*.tsv と data/*.json（言語非依存）。

// ── git ──────────────────────────────────────────────
export interface GitInfo {
  branch: string;
  lastCommit: string;
  dirty: number;
  ahead: number | null;
}

// ── GitHub Project（ボード）─────────────────────────────
export interface BoardItem {
  number: number | null;
  title: string;
  status: string;
  repo: string;
  url: string | null;
}

export interface Board {
  counts: Record<string, number>;
  total: number;
  doneRate: number;
  active: BoardItem[];
  number?: string;
  url?: string;
  error?: string;
}

// ── PR ───────────────────────────────────────────────
export interface PullRequest {
  number: number;
  title: string;
  createdAt: string;
  url: string;
  isDraft: boolean;
}

// ── App Store Connect ────────────────────────────────
export interface AppVersion {
  version: string | null;
  platform: string | null;
  state: string;
  stateLabel: string;
  createdDate: string;
}

export interface ReviewSubmission {
  state: string;
  stateLabel: string;
  platform: string | null;
  submittedDate: string;
}

export interface CustomerReview {
  rating: number | null;
  title: string;
  body: string;
  nickname: string;
  territory: string;
  createdDate: string;
}

export interface Reviews {
  total: number | null;
  avgOfRecent: number | null;
  items: CustomerReview[];
}

export interface AppBuild {
  build: string | null;
  state: string;
  stateLabel: string;
  expired: boolean;
  uploadedDate: string;
}

export interface MetricCategory {
  category: string;
  metric: string | null;
  sample: string | null;
}

export interface AppRecord {
  appName: string;
  appId: string;
  bundleId: string;
  versions: AppVersion[];
  reviewSubmissions: ReviewSubmission[];
  reviews: Reviews;
  builds: AppBuild[];
  metrics: { categories: MetricCategory[]; error?: string };
  error?: string;
}

// ── プロジェクト / ダッシュボード ──────────────────────────
export interface Project {
  name: string;
  path: string;
  note: string;
  repo: string | null;
  exists: boolean;
  git: GitInfo | null;
  board: Board | null;
  prs: PullRequest[];
  appstore: AppRecord | null;
}

export interface Dashboard {
  generatedAt: string;
  projects: Project[];
}

// ── 手動レイヤー（Claude が編集）────────────────────────
export interface Pin {
  project: string;
  number: number;
  reason: string;
}

export interface ManagerState {
  _comment?: string;
  updatedAt: string;
  focusNotes: string[];
  pinned: Pin[];
  autoHighlightKeywords: string[];
}
