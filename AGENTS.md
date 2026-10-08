# AGENTS.md — agent 工作约定（每次会话先读）

## 实例管理（硬性规则）

**任何常驻实例同一时刻只允许运行一个"最新版"实例。** 覆盖对象：WERSS菜单栏.app、batch/run_forever.sh（采集 runner）、docker 容器、ego 浏览器 worker、以及今后新增的任何常驻进程。

- 启动/重启前必须先停旧的、确认已停，再拉新的；不要盲目叠加启动。
- **菜单栏 app 重启唯一正确姿势**：`launchctl kickstart -k gui/$(id -u)/com.werss.menubar`（杀旧+拉新一步完成）。**禁止用 `open -a` 手动重启**——open -a 会与 launchd 各拉一个，撞出双实例（2026-10-04 实际发生，用户明确要求杜绝）。
- **菜单栏退出语义（2026-10-05 起）**：launchd KeepAlive 是 `SuccessfulExit: false`——只在崩溃/被信号杀时自动拉起；菜单「退出菜单栏」或 osascript quit 等**正常退出（exit 0）后不会再自动起来，是真退出**。想再拉起：`launchctl kickstart gui/$(id -u)/com.werss.menubar`（不带 -k，任务仍加载只是没在跑）。发现菜单栏不在了先查 `launchctl print` 的 `last exit code`，别当故障乱修。
- 应用内已有兜底：`menubar_app.swift` 的 `dedupeInstances()` 按 pid 只保留最新实例（新实例淘汰旧实例）。
- `bin/build_menubar.sh` 构建成功后会自动经 launchctl kickstart 重启运行中的应用，无需手动补操作。
- runner：经 `bin/lib.sh` 的 `stop_runner` / `start_runner` 管理；`run_forever.sh` 自带目录锁单实例守卫，不要绕过它手动起第二个。

## 在场闸：菜单栏图标是唯一的"在场"信号（2026-10-08 用户定规则）

**用户原话：「有相关服务必须建立在 menubar icon 在的基础上。不然用户感知不到，像是缺陷而不是功能。」**

菜单栏退出 = 用户不在了。此时一切后台行为都必须静默——状态在面板里看不见，
用户只会收到一条无入口的横幅，感知为缺陷而不是功能。落地约定：

- 单一判定函数：`bin/lib.sh` 的 `menubar_present()`（匹配 `WERSS菜单栏.app/Contents/MacOS/main`）。
  **新增任何常驻/定时组件时，第一件事就是 `if ! menubar_present; then exit 0; fi`。**
- `bin/keepalive.sh` 顶部第 0 步就是这道闸：菜单栏不在场则不检测授权、不拉
  Docker/容器/runner、不发通知、不写事件、不做更新检查。
- 通知三档，**不要混用**：
  - `notify_now` —— 用户亲手双击触发的流程（控制台.app / 导入导出 / 安装 / 扫码页），无条件发。用户就站在终端前，属于"感知得到"。
  - `notify` —— 后台/自治通知，受在场闸约束，菜单栏不在只落日志。
  - `notify_important` —— 故障告警，**永不自行发 osascript**，只写 `.alert-state-*` + 日志。菜单栏在场时由它每 30 秒自检 `status.sh` 发可点击通知（自带 1800s 冷却，见 `menubar_app.swift:594`）。
- **反面教训（2026-10-08 实测）**：`notify_important` 曾在菜单栏缺席时用 osascript 兜底推送，
  结果用户退出菜单栏后仍每 31 分钟被轰炸一次（当天 27 条）。**"菜单栏不在就自己补一条通知"是错的设计方向**，别再写回去。
- **退出即停服（2026-10-08 用户定规则）**：「关闭 menubar icon 意味着这件事相关的服务我都不再需要了」。
  菜单栏「退出菜单栏」会派发 `bin/stop.sh`（停 runner + `compose stop` 停 `we-mp-rss` 容器，
  只停不删，数据在 bind mount）后才退出 UI，见 `menubar_app.swift:quit()`。
  - **不要**把钩子挂 `applicationWillTerminate`——那会让崩溃路径也停服，而崩溃时 launchd 会自动拉回菜单栏，服务本就该继续。
  - **不要**停 Docker Desktop：同机还有 hlpp-analytics / neststack 等容器在跑，与本项目无关。
  - 恢复：`bash bin/start.sh`（拉起全套）；菜单栏启动时会自动补跑一轮 `keepalive.sh` 把服务拉回来
    （`applicationDidFinishLaunching`，否则要干等 keepalive 的 30 分钟间隔），也可菜单里点「立即自动修复」。
- `bin/build_menubar.sh` **按进程**判定是否重启菜单栏，不能只看 `launchctl print`
  （任务常驻加载，用户退出后 print 仍成功 → 会把用户刚退掉的图标硬拉回来并恢复整套服务）。

## 项目数据约定

- `batch/mp_match_ledger.json`：公众号匹配的轮次台账唯一权威（每轮独立记录，含已试关键词与 AI 理由）；后续轮次的去重与经验都从这里读。
- `logs/events.jsonl`：结构化事件日志（菜单栏「全量日志」窗口数据源）；类型含 added / not_found / pending_review / abort / canary / chunk / runner / keepalive / **scan**（微信读书与公众号主授权的失效/恢复/打开扫码页）。**scan 事件的唯一来源是菜单栏应用**（30 秒级实时检测状态变化，`notifyOnTransitions` + `emitEvent`）；keepalive 只做系统级兜底（`notify_important` 仅落 `.alert-state-*` 与日志，不自行发通知），不写 scan 事件，避免重复。普通事件保留 7 天（keepalive 自动清理），`added` 类型豁免（第一/二批成功记录永久可筛）。
- `companies.csv` 是人读台账；`wx_mp_tried_names` 由 process_chunk 合并追加，不要整格覆盖。

## 排查线索：runner 一直 0 进展 / 报 search_throttled

`abort` 文案是**推测**不是事实。2026-10-04 曾因「数据库故障被伪装成限流」白转 7 小时。
按顺序查这三处（本项目历史上出现过两个独立故障叠加，只修一个不够）：

1. **we-mp-rss 数据库能不能写** —— `docker logs we-mp-rss | grep -c "disk I/O error"`。
   `./data` 是 bind mount，SQLite WAL 需要 mmap，Docker Desktop 下会间歇性挂。
   症状：登录接口 500，页面报「用户名或密码错误,您的帐号已锁定」（**这是前端兜底文案，假的**）。
   解法：`docker compose --env-file config.env -f docker-compose.yml restart we-mp-rss`。
2. **微信授权是否还有效** —— `curl -X POST $WERSS_APP_URL/api/v1/wx/weread/test`，
   失效时返回 `code:400 Cookie 可能已过期`；或看 `logs/.wx_probe_cache` 是否 `EXPIRED`。
   **公众号搜索与微信读书共用同一套授权**，授权一失效，搜索接口返回 `code 50001`，
   批量添加会一起停（别信 keepalive 早期文案里「账号添加不受影响」，已修正）。
   需人工扫码：`bash bin/open_scan_page.sh --wx`（`--wx` 才是公众号主授权页）。
3. **真的限流** —— 只有前两项都正常、金丝雀仍搜到 0 条，才是限流。此时才长冷却。

`batch/process_chunk.py` 的 `canary_failure()` 已把上述四类分开
（`search_throttled` / `env_auth_expired` / `env_login_failed` / `env_broken`），
`run_forever.sh` 只对 `search_throttled` 冷 40 分钟，其余 5 分钟重试。
**新增故障类型时改这两处，不要再加一个 `if xxx==0 就报限流`。**

## 其他

- 代码改动一般不主动 commit，除非用户明确要求。
- MiniMax-M3 是推理模型：max_tokens 要给足（≥3000），JSON 输出需容错解析；runner 环境 python 是 /usr/local/bin/python3，其默认证书链会撞自签 CA，HTTPS 需用 certifi 上下文。
