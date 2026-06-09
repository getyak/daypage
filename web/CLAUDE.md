# DayPage Web

- 启动开发必须同时跑 `npm run dev`（:3000）和 `npm run dev:inngest`（:8288）。只跑前者，AI 编译不会发生，memo 永远卡在 Compile Queue（`compile_status=pending`）且无任何报错——因为 `src/lib/inngest/client.ts` 的 `sendEvent()` 在无 `INNGEST_EVENT_KEY` 的 dev 下静默 no-op。排查 memo 卡住先查这里，不是代码 bug。
- 重跑卡住的 memo（Inngest 在跑时）：`curl -s http://localhost:8288/e/dev -X POST -H "Content-Type: application/json" -d '{"name":"memo/created","data":{"memo_id":"<ID>"}}'`。绕过 auth，比页面 Recompile 快。
- 验证 UI 用 dev 登录：login 页 "Dev login (no email)"，用户 `dev@daypage.local`。别配真实 OAuth。
- 查 memo 真实状态以 DB 为准（UI 会骗你）：`psql "$DATABASE_URL" -c "select compile_status, compile_error from memos where id='<ID>';"`。
- Dev login 点了报 500 `CallbackRouteError` / 服务端日志 `ECONNREFUSED 127.0.0.1:54322`，是本地 Postgres 没起（不是代码 bug）——根因往往是 Docker 引擎（OrbStack）没开；修复顺序：`open -a OrbStack` 等 `docker info` 就绪 → 仓库根 `supabase start`（会自动应用 migration）→ 再跑 web。
