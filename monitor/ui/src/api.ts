// 応答の読み取り。サーバーが古いと Hono 既定の `404 Not Found`（JSON ではない）が返り、
// そのまま res.json() に通すと SyntaxError の文言がそのまま画面に出てしまう。

export interface ApiResult {
  ok: boolean;
  error?: string;
}

export async function readResult(res: Response): Promise<ApiResult> {
  const body = await res.text();
  try {
    return JSON.parse(body) as ApiResult;
  } catch {
    if (res.status === 404) {
      return { ok: false, error: "サーバーがこの操作を知りません（monitor の再起動が要ります）" };
    }
    return { ok: false, error: `応答を読めません（HTTP ${res.status}）` };
  }
}
