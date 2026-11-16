# AIUsageBar — 專案規則

macOS 狀態列工具，顯示 ChatGPT / Claude / Gemini 訂閱額度。說明見 `README.md`，目前狀態見 `HANDOFF.md`。

## 環境

- 只有 Command Line Tools（沒有 Xcode、沒有 XCTest）。建置與測試一律 `./build.sh`（`install` 參數會安裝並重啟）。
- `-swift-version 5`、目標 macOS 14+（`NSImage` 讀 SVG 需要 14）、ad-hoc 簽章。不加任何第三方依賴。

## 硬規則

- **永遠不換發 refresh token。** Claude / Codex 的 refresh token 會輪替，換發會把使用者的 CLI 登出。
- **只有使用者按「切換」才寫入 CLI 登入位置**（`switchAccount`）：寫之前一定先把目前登入存進 vault 並備份設定檔。其他路徑一律只讀。
- 帳號副本只放 `~/Library/Application Support/AIUsageBar/accounts/`、權限 0600；`security -i` 一行約 4KB 上限，寫鑰匙圈前檢查長度並讀回比對。
- 公開 repo：截圖只能用 `--render-dashboard` 的 `-states.png`（全部假資料），不放含真實帳號的圖；截圖放 release 附件，不進 git。
- **不印出、不記錄任何 token**（`--dump`、紀錄檔、錯誤訊息都一樣）。
- 不呼叫、不內嵌外部專案的程式碼；只能參考文件自行實作。
- 「點此登入」只會開使用者看得到的終端機視窗跑寫死的登入指令；不在背景代跑登入、不碰瀏覽器。
- 自簽憑證只對 `127.0.0.1` 放行（`LocalhostTrust`），不可放寬。

## 驗證

- 改解析器：在 `Sources/SelfTest.swift` 補案例，`./build.sh` 會擋。
- 改帳號存取／切換：`--accounts-test`（暫存檔＋測試用鑰匙圈項目，不碰真正的登入）。
- 改抓取：`--dump` 實跑。改狀態列外觀：`--snapshot x.png` 看圖。改儀表板：`--render-dashboard x` 看淺色／深色／異常狀態三張圖。改位置相關：`--where`。改登入流程：`--terminal-test <檔案>`（不會真的觸發登入）。
- 這台沒有螢幕錄製權限，`screencapture` 拍不到選單列內容，不要拿它當驗證。

## 地雷

- macOS 26 的狀態列項目由控制中心代管，`occlusionState` 一律回報不可見，不能用來判斷有沒有顯示；System Events 也抓不到 `menu bar 2`，無法用 AppleScript 模擬點擊。
- SwiftUI 不用 `@Observable`／`#Preview` 這類巨集，用 `ObservableObject`，避免依賴 Xcode 才有的巨集外掛。
- 儀表板截圖用離屏 `NSHostingView` + `cacheDisplay`，不要用 `ImageRenderer`（AppKit 底層的按鈕、勾選框畫不出來）。
- Antigravity 的 `GetUserStatus` 每個模型只給「目前卡住的那一格」（大多是 5 小時），看不到週額度；週額度要用 `RetrieveUserQuotaSummary`（群組 → buckets，`window` 為 `5h`／`weekly`）。舊版沒有這個介面時才退回逐模型的數字。
- Antigravity 回應是 protobuf 轉 JSON：`remainingFraction` 為 0 時欄位會消失，有 `resetTime` 沒有比例要當成用完。
