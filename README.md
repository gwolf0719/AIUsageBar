# AIUsageBar

macOS 狀態列小工具：同時顯示 ChatGPT、Claude、Gemini 訂閱的**剩餘額度**與**距離重置的時間**，支援每家多個帳號。
直接讀本機 CLI 的登入狀態，不需要另外登入，也沒有任何第三方依賴（純 Swift，AppKit + SwiftUI）。

A macOS menu bar app showing remaining quota and reset times for ChatGPT (Codex CLI), Claude (Claude Code) and Gemini (Antigravity), with multi-account switching. No dependencies, no telemetry.

![儀表板（示範資料）](https://github.com/gwolf0719/AIUsageBar/releases/download/v1.0.1/screenshot.png)

狀態列每家一欄：上排是品牌圖示＋最緊那個額度的剩餘百分比，下排是多久後重置。

- 剩餘不足 20%：上排反白。
- 抓不到新資料（未登入、離線、Antigravity 沒開）：整欄變淡，顯示上次紀錄；完全沒資料顯示 `—`。
- 點狀態列彈出儀表板：每家一張卡，大字是最緊那個額度的剩餘、右側是下次重置，下面列出所有額度的進度條（綠／黃／紅依剩餘量）、重置倒數與時刻。支援淺色／深色。
- **多帳號**：卡片右上角的 ⋯ 選單可以「登入其他帳號」「切換到…」「移除帳號」。卡片下方「其他帳號」列出沒在使用的帳號：
  它們存下的登入還有效就即時查詢（標示「即時」），過期了就顯示最後一次的數字，已過重置時間的額度視為回滿。
  按「切換」會先把目前帳號的登入存起來，再把選定帳號寫回 CLI；已經開著的 `codex` / `claude` 要重開才會換帳號。
  Gemini 的帳號在 Antigravity 裡切換，這裡只記錄各帳號最後的數字。
- 未登入時狀態列下排顯示「未登入」，卡片上出現「登入」按鈕：ChatGPT / Claude 會開終端機執行 `codex login` / `claude auth login`（在瀏覽器完成授權），Gemini 會開啟 Antigravity。之後 5 分鐘內每 15 秒自動檢查一次，登入完成就會更新。

## 資料來源

| 欄 | 登入狀態從哪裡讀 | 用量從哪裡查 |
|---|---|---|
| GPT | `~/.codex/auth.json`（Codex CLI） | `chatgpt.com/backend-api/wham/usage` |
| CL | 鑰匙圈 `Claude Code-credentials`，其次 `~/.claude/.credentials.json`（Claude Code CLI） | `api.anthropic.com/api/oauth/usage` |
| GM | 執行中的 Antigravity（`language_server` 的啟動參數與本機連接埠） | 本機 `RetrieveUserQuotaSummary`（各模型群組的 5 小時與每週額度）＋ `GetUserStatus`（方案、帳號），不經外網 |

平常只讀不寫。例外是 Claude 使用中的帳號：鑰匙圈裡的 token 約 8 小時到期，過期時本工具會替它換新並寫回鑰匙圈
（跟 Claude Code 自己做的事一樣；換之前會先確認寫得回去，換到的新 token 先存檔再寫回，避免把 CLI 登出）。
Codex 與不在使用中的帳號不會換發，過期時開一次對應的 CLI 就會自動更新。除此之外，會寫入 CLI 登入位置的只有你按下「切換」的時候：
Codex 寫 `~/.codex/auth.json`，Claude 寫鑰匙圈並更新 `~/.claude.json` 的 `oauthAccount`（寫之前先備份）。

各帳號的登入副本存在 `~/Library/Application Support/AIUsageBar/accounts/`（權限 0600，跟 CLI 自己的 auth.json 同等級），
不會上傳到任何地方。移除帳號會刪掉副本。

Gemini CLI（`~/.gemini/oauth_creds.json`）這個帳號查配額會回 403 `SUBSCRIPTION_REQUIRED`，
實際額度掛在 Antigravity 上，所以 GM 欄改走 Antigravity；Antigravity 沒開時顯示上次紀錄。

## 安裝

需要 macOS 14 以上。

**下載**：到 [Releases](https://github.com/gwolf0719/AIUsageBar/releases) 下載 `AIUsageBar-<版本>.dmg`，把 AIUsageBar 拖進「應用程式」。
沒有 Apple 開發者簽章與公證，第一次打開會被擋：在 Finder 對 app 按右鍵 →「打開」，或執行

```bash
xattr -dr com.apple.quarantine /Applications/AIUsageBar.app
```

**自己編譯**（只需要 Xcode Command Line Tools）：

```bash
./build.sh install
```

會編譯（Apple Silicon + Intel 通用版）、跑自我測試、安裝到 `~/Applications/AIUsageBar.app` 並啟動。
打包發布檔：`./release.sh 1.0.0` 產生 `build/AIUsageBar-1.0.0.dmg` 與 `.zip`。
開機自動啟動：勾選儀表板底部的「登入時自動啟動」。

## 紀錄

`~/Library/Application Support/AIUsageBar/`

- `history.jsonl`：每 5 分鐘查一次，數值有變動才追加一行（provider、方案、各視窗已用百分比與重置時間）。
- `last.json`：最近一次成功的結果，重啟或離線時先顯示這份。
- `accounts/accounts.json`：各帳號（不含 token）最後的數字；`accounts/<家>-<雜湊>.json`：各帳號的登入副本。

## 驗證用參數

```bash
build/AIUsageBar.app/Contents/MacOS/AIUsageBar --selftest          # 解析器自我測試（build.sh 每次都跑）
build/AIUsageBar.app/Contents/MacOS/AIUsageBar --dump              # 實際抓一次並印出
build/AIUsageBar.app/Contents/MacOS/AIUsageBar --snapshot out.png  # 輸出狀態列圖像
build/AIUsageBar.app/Contents/MacOS/AIUsageBar --render-dashboard out  # 儀表板截圖：out-light/-dark/-states/-short.png
build/AIUsageBar.app/Contents/MacOS/AIUsageBar --where             # 印出狀態列項目的螢幕位置
build/AIUsageBar.app/Contents/MacOS/AIUsageBar --terminal-test /tmp/x  # 用登入同一條路徑開終端機，只建立標記檔
build/AIUsageBar.app/Contents/MacOS/AIUsageBar --accounts-test     # 用暫存檔＋測試鑰匙圈項目演練切換帳號
```

## 看不到圖示？

瀏海機種選單列項目太多時，系統會把放不下的項目藏起來。本工具第一次啟動會預設排在靠右的位置；
仍看不到時按住 ⌘ 拖曳其他圖示移出選單列騰出空間，或用 `--where` 確認位置。

## 授權與商標

程式碼以 MIT 授權釋出（見 `LICENSE`）。品牌圖示取自 [Simple Icons](https://simpleicons.org)（CC0），
OpenAI、Claude、Gemini 的名稱與標誌屬於各自的公司，本專案與它們沒有關係。

## 參考

做法參考 [steipete/CodexBar](https://github.com/steipete/CodexBar) 的文件（端點與欄位），程式碼全部自行撰寫，沒有引用或呼叫外部程式碼。
這些都是各家未公開的內部端點，改版後可能失效；失效時儀表板會顯示 HTTP 狀態碼。
