# DayPage Web

- 启动开发必须同时跑 `npm run dev`（:3000）和 `npm run dev:inngest`（:8288）。只跑前者，AI 编译不会发生，memo 永远卡在 Compile Queue（`compile_status=pending`）且无任何报错——因为 `src/lib/inngest/client.ts` 的 `sendEvent()` 在无 `INNGEST_EVENT_KEY` 的 dev 下静默 no-op。排查 memo 卡住先查这里，不是代码 bug。
- 重跑卡住的 memo（Inngest 在跑时）：`curl -s http://localhost:8288/e/dev -X POST -H "Content-Type: application/json" -d '{"name":"memo/created","data":{"memo_id":"<ID>"}}'`。绕过 auth，比页面 Recompile 快。
- 验证 UI 用 dev 登录：login 页 "Dev login (no email)"，用户 `dev@daypage.local`。别配真实 OAuth。
- 查 memo 真实状态以 DB 为准（UI 会骗你）：`psql "$DATABASE_URL" -c "select compile_status, compile_error from memos where id='<ID>';"`。
