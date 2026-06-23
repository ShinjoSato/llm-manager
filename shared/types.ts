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

// ── Google カレンダー ─────────────────────────────────
export interface CalendarEvent {
  id: string;
  title: string;
  start: string;   // ISO（終日は YYYY-MM-DD）
  end: string;
  allDay: boolean;
  location: string;
  url: string | null;
}

export interface CalendarData {
  events: CalendarEvent[];
  rangeDays: number;
  error?: string;
}

export interface Dashboard {
  generatedAt: string;
  projects: Project[];
  calendar?: CalendarData | null;
  ranking?: RankingData | null;
  trends?: TrendsData | null;
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

// ── App Store ランキング（Apple Marketing Tools RSS v2・無料/キー不要）─────
export interface RankingApp {
  rank: number;
  appId: string;        // App Store の数値 ID（RSS の id）
  name: string;
  artistName: string;
  url: string;
  artworkUrl: string | null;
  releaseDate: string;
}

export interface RankingChart {
  country: string;      // jp / us ...
  kind: string;         // top-free / top-paid / top-grossing
  title: string;        // RSS の feed.title（例: 無料アプリ）
  updated: string;      // RSS の更新日時
  apps: RankingApp[];
  error?: string;
}

/** 自アプリがどのチャートで何位か。圏外なら rank=null。 */
export interface OwnAppRank {
  project: string;      // 管理対象名（mirio / sandora）
  bundleId: string;
  appId: string | null; // 解決できれば数値 ID（要 App Store Connect 認証）
  ranks: { chart: string; rank: number | null }[]; // chart = "jp/top-free" 等
}

export interface RankingData {
  charts: RankingChart[];
  ownApps: OwnAppRank[];
  error?: string;
}

// ── Google Trends 急上昇（公式 RSS・無料/キー不要）─────────────────────
export interface TrendNews {
  title: string;
  source: string;
  url: string;
}

export interface TrendItem {
  title: string;          // 急上昇ワード
  approxTraffic: string;  // 例: "100+"
  pubDate: string;
  picture: string | null;
  news: TrendNews[];
}

export interface TrendsData {
  geo: string;            // JP ...
  updated: string;        // channel の更新（無ければ最初の item の pubDate）
  items: TrendItem[];
  error?: string;
}
