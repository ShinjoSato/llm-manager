// 収集して data/dashboard.json に書き出す CLI（Python版 collect.py 相当）。
import { collectAndSave } from "./core/collect.js";

const dash = await collectAndSave();
console.log(`書き出し: data/dashboard.json (${dash.projects.length} プロジェクト)`);
