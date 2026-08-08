# herdr-limit-relay

> 本文件為正本（canonical）。English: [README.md](README.md)（翻譯，可能落後）。

Claude Code 撞到 5 小時用量限制時，自動接手。針對 **herdr 0.8.0** 撰寫。

兩個選項，共用同一個偵測層：

| | 做什麼 | 適合 |
|---|---|---|
| **Option A — `resumer.sh`** | 等限制解除，喚醒原本那個 Claude session | 單一 provider，你只想要「早上起來工作做完了」 |
| **Option B — `relay.sh`** | 等待期間開一個 git worktree，讓 Codex 跑安全清單；Claude 回來後接手 review | 你有 Codex/Grok 訂閱，不想浪費那 5 小時 |

兩個可以同時裝。Option B 內部會呼叫 Option A 的續跑邏輯。

---

## 架構

```text
Claude Code (in herdr pane)
   │
   │ StopFailure hook (matcher: rate_limit)   ← 官方結構化事件，非文字比對
   ▼
hooks/limit-watch.sh
   ├─ append → ~/.herdr-limit/ledger.jsonl   { pane, session_id, cwd }
   ├─ herdr pane report-metadata             ← sidebar 顯示 "rate limited"
   └─ herdr notification show
   
bin/resumer.sh (daemon, 不吃 token)
   ├─ 每 5 分鐘用 haiku 探針測試額度是否恢復
   ├─ pane 還活著 → herdr agent prompt --wait
   └─ pane 已死   → herdr workspace create + agent start --kind claude -- --resume <sid>

bin/relay.sh (daemon, Option B)
   └─ 限制觸發當下 → herdr worktree create + agent start --kind codex
```

**為什麼偵測用 hook 而不是掃畫面**：`StopFailure` 的 matcher 直接支援 `rate_limit`，是官方的結構化事件，帶 `session_id` 和 `cwd`。社群那些 tmux 工具花幾百行做的 ANSI 剝除 + banner regex + 時區解析，這裡全部不需要。

**為什麼不解析重置時間**：`StopFailure` 的 input schema 官方至今沒文件化（[anthropics/claude-code#35620](https://github.com/anthropics/claude-code/issues/35620)），不保證有重置時間。所以我們改用 haiku 探針輪詢——時區、DST、banner 格式變更三個最脆弱的環節直接消失。代價是最多晚 5 分鐘恢復。

---

## 安裝

前置：`herdr` ≥ 0.8.0、`jq`、Claude Code、`~/.claude` 已存在。
目前僅在 macOS 上測試（launchd、osascript）；Linux 相關指引僅供參考。

```bash
# 1. 先裝 herdr 官方 claude 整合（如果還沒）
herdr integration install claude
herdr integration status          # 確認 Claude Code integration version >= 6

# 2. 裝這套
cd herdr-limit-relay
./install.sh
```

`install.sh` 會：

- 複製 hook 到 `~/.claude/hooks/limit-watch.sh`
- 用 jq **合併**（非覆寫）`StopFailure` 條目進 `~/.claude/settings.json`，並先備份
- 建立 `~/.herdr-limit/`
- 印出 daemon 的啟動指令

**注意：hook 是複本。** `install.sh` 把 `hooks/limit-watch.sh` **複製**到
`~/.claude/hooks/`，所以之後在 repo 裡修改 hook（或 `git pull` 更新），
已安裝的那份不會跟著變——改完必須重跑 `./install.sh`。

另外會裝一個**診斷用**的無 matcher StopFailure hook
（`stopfailure-raw.sh`）：任何 StopFailure 的原始 payload 都會原封寫進
`~/.herdr-limit/stopfailure-raw.jsonl`。官方沒文件化這個 schema
（見下方已知限制），所以第一筆真實事件就能驗證 `rate_limit` matcher
的前提、以及有沒有重置時間可用——不用等到第一次真的撞限制才知道。

裝完驗證：

```bash
./bin/selftest.sh --post-install
./bin/test-hook.sh              # 離線測 hook 解析，不需要 herdr、不吃 token
jq '.hooks.StopFailure' ~/.claude/settings.json
claude   # 在 herdr pane 裡開，然後 /hooks 應該看到 StopFailure
```

移除：`./uninstall.sh` 只拿掉本工具的 StopFailure 條目（herdr 自己的
hook 不動）並刪除複製過去的 hook；daemon／launchd／`~/.herdr-limit/`
要自己清，結尾會列提醒。

---

## Option A：本地續跑

```bash
# 前景跑（先這樣測）
./bin/resumer.sh

# 常駐（macOS）：launchd，登入自動啟動、掛掉自動重啟
sed -e "s|__REPO__|$PWD|g" -e "s|__HOME__|$HOME|g" \
    templates/resumer.launchd.plist \
    > ~/Library/LaunchAgents/com.herdr-limit.resumer.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.herdr-limit.resumer.plist

# 或者：放進一個 herdr pane 手動跑
herdr workspace create --label ops --no-focus
# 然後在那個 pane 裡跑 ./bin/resumer.sh
```

之後更新過 `bin/resumer.sh` 記得重啟 daemon（launchd 跑的是啟動當下的
程式碼）：`launchctl kickstart -k "gui/$(id -u)/com.herdr-limit.resumer"`

可調環境變數：

| 變數 | 預設 | 說明 |
|---|---|---|
| `RESUME_POLL_SECONDS` | `300` | 探針間隔。別調太低，每次探針都算一次請求 |
| `RESUME_PROBE_MODEL` | `haiku` | 探針模型，用最便宜的 |
| `RESUME_MESSAGE` | 見腳本 | 續跑時送出的 prompt |
| `RESUME_MAX_ATTEMPTS` | `5` | 單一 session 重試上限，避免無限迴圈燒額度 |
| `RESUME_TIMEOUT_MS` | `1800000` | 等 agent 跑完的上限（30 分鐘） |
| `RESUME_PROBE_BROKEN_ALERT` | `3` | 探針連續因「非限制原因」失敗幾次後發通知（網路斷、認證失效、CLI 壞掉） |

**續跑 prompt 要保守。** 預設是 `Continue where you left off. If the task is already complete, reply DONE and stop.` 明確給它一個停止出口，否則它可能在新視窗裡自由發揮把額度再燒光。

---

## Option B：跨 provider 接手

```bash
export RELAY_AGENT_KIND=codex        # 或 grok / gemini / opencode
./bin/relay.sh
```

限制觸發時，`relay.sh` 會：

1. 從原本的 repo 建一個 git worktree（分支 `nightshift/YYYYmmdd-HHMM`）
2. 在新 workspace 裡 `herdr agent start --kind codex`
3. 只餵它 `TASKS.md` 裡標記 `[relay-safe]` 的項目
4. 每完成一項就 commit，並寫進 `RELAY-LOG.md`
5. Claude 回來後，`resumer.sh` 會先叫 Claude review 那個分支

### 為什麼要 worktree

兩個不同 provider 的 agent 同時編輯同一棵工作樹 = 互相覆寫的災難。`herdr worktree create` 是原生指令，一行就做完隔離。

### 交接協議

跨 provider **不可能傳遞對話歷史**。Claude 的 transcript 在 `~/.claude/projects/*.jsonl`，Codex 讀不懂。能傳的只有落在磁碟上的東西：

| 載體 | 說明 |
|---|---|
| `TASKS.md` | 最重要。兩邊都必須每完成一步就更新 |
| `CLAUDE.md` / `AGENTS.md` | 專案慣例。建議 symlink 讓兩邊讀同一份 |
| git commits + diff | 最誠實的狀態來源 |
| `RELAY-LOG.md` | 接手方寫給原本那個 agent 看的 |

`templates/` 裡有兩份範本：`TASKS.md` 直接複製到專案根目錄；
`RELAY-CONTRACT.md`（替補 agent 契約）則是**附加**到你專案既有的
`AGENTS.md`——不要取代那個檔案，這份契約只適用於替補 agent 的情境，
拿來當日常開發規範是錯的。

### 什麼任務標 `[relay-safe]`

只標**機械性、可驗證、失敗成本低**的：補測試、寫 docstring、修 lint、更新 README、處理 TODO 註解、依賴升級。

**不要標**：架構決策、跨檔重構、schema/migration 變更、任何碰 CI/部署設定的東西。這些等 Claude 回來做。

---

## 安全設計（每一條都是刻意的）

| 風險 | 這套怎麼處理 |
|---|---|
| 送鍵送到錯的程式 | 用 `herdr agent prompt` 而非 `pane send-keys`。文件：<agent input 會解析當前 agent，若該 agent 已不控制該 pane 就拒絕操作> |
| pane id 被回收，訊息送給別人 | 同上，`agent prompt` 原生擋掉；`agent wait` 也會 pin 住解析到的 pane 佔用者 |
| 誤選到限制選單的「Upgrade your plan」 | 完全不碰選單。只用 `agent prompt` 送文字 |
| 奪走 herdr 整合的狀態權限 | 用 `pane report-metadata`（display-only），不用 `report-agent` |
| 無限重試燒光額度 | `RESUME_MAX_ATTEMPTS`，超過就放棄並通知 |
| 無人值守時 agent 亂改東西 | **沒有** `--dangerously-skip-permissions`。Option B 靠 worktree 隔離而非跳過權限 |
| 腳本壞掉但你不知道 | `healthcheck.sh` + heartbeat 檔案，見下 |

---

## Dead man's switch（一定要裝）

herdr 是 0.8.0，protocol v15，還在跳號。你的腳本會在某次升級後壞掉，而你會在**隔天早上發現整夜什麼都沒做**才知道。

```bash
# macOS：用 launchd。crontab 第一次寫入要等 TCC 核准，對話框只會出現在
# 本機螢幕上——從 SSH session 跑會直接卡死。
sed -e "s|__REPO__|$PWD|g" -e "s|__HOME__|$HOME|g" \
    templates/healthcheck.launchd.plist \
    > ~/Library/LaunchAgents/com.herdr-limit.healthcheck.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.herdr-limit.healthcheck.plist

# Linux：crontab -e
# 0 * * * * /path/to/herdr-limit-relay/bin/healthcheck.sh
```

注意：launchd agent 掛在 `gui` domain，機器上的使用者登出就會停；無人值守的機器請保持登入（或改寫成 LaunchDaemon）。

`healthcheck.sh` 檢查 `~/.herdr-limit/heartbeat` 的 mtime，超過 3 倍輪詢間隔沒更新就發桌面通知。

另外強烈建議：

```bash
herdr channel set stable      # 別用 preview
# 升級前先跑一次 ./bin/selftest.sh
```

---

## 已知限制 / 需要自行驗證的地方

1. **`herdr agent get` 的 JSON 欄位名稱**我沒有逐一驗證。腳本刻意寫成「只看 exit code，不 parse 欄位」——`agent get` 成功就當 pane 活著，`agent prompt` 失敗就退到重建路徑。這樣升級後不容易壞。要看確切 schema：`herdr api schema --json | jq`。

2. **`agent prompt --wait` 的 stall 行為**：從非 working 狀態送出時，herdr 要求 5 秒內觀察到生命週期變化，否則回 `agent_prompt_stalled`。腳本有處理這個錯誤並重試。

3. **舊版指令語法不同**。網路上很多 herdr 教學寫的是 `herdr wait output 1-3 --match ...`，那是 0.6 之前的形式。0.8.0 是 `herdr pane wait-output w1:p1 --regex ...`，pane id 是 `w1:p1` 格式。以 `herdr --help` 和官方 socket API 文件為準。

4. **探針會消耗一次請求**。`RESUME_POLL_SECONDS=300` 表示每小時 12 次 haiku 請求，可忽略，但別調到 30 秒。

5. **這套不處理 weekly limit**。撞到週限制時，探針會持續失敗好幾天，`RESUME_MAX_ATTEMPTS` 不會觸發（因為根本沒送出）。腳本會一直輪詢，這是刻意的——但你會收到 healthcheck 通知。

6. **herdr 是 AGPL-3.0**。自己用沒問題；包進產品或做託管服務要看清楚義務。
   本 repo 只以 shell 呼叫 `herdr` 執行檔、沒有連結它的程式碼，所以不
   承擔 AGPL 義務——本 repo 本身採 MIT 授權（見 `LICENSE`）。
