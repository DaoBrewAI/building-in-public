# Session policy

Reviewed against official OpenAI guidance on 2026-09-08. Recheck support when
selecting a different model or launch surface.

## Model, effort and speed are separate

| Decision | Default | Evidence |
|---|---|---|
| Supervisor | Keep the user's selected model/effort for difficult planning and acceptance | Actual task setting |
| Worker | GPT-6 Astra medium for ambiguous integration; GPT-5.6 Sol high for frozen, bounded work | Node-specific rationale and actual setting |
| Speed | Standard/non-Fast, day and night | Explicit launch option or captured launch config plus runtime evidence |

Honor explicit model choices and host availability. Effort labels are not a
cross-model quality scale. Routine workers do not inherit ultra/max from the
supervisor; a user-requested highest-effort worker records that override.

## GPT-6 Ultra and API settings

Some Codex hosts expose `ultra`; the public GPT-6 Astra API guide lists `low`,
`medium`, `high`, `xhigh` and `max`. Preserve a supported user-selected app Ultra
supervisor. Do not invent an `ultra` API argument or claim it equals `max`.
The active host tool schema determines which arguments can be passed.

## Fast is opt-in only

Use `service_tier: "default"` and Fast false where exposed. Do not pass extra
unsupported fields. Local Codex launch defaults can use `service_tier = "default"`
and `[features] fast_mode = false` where supported. A current non-Fast instruction
overrides older memory, examples, daytime rules and inherited priority settings.

If the launch API lacks a tier argument:

1. Inspect supported per-thread/default controls.
2. Preserve unrelated config; change only an authorized launch default if needed.
   Do not restart the desktop app or disturb active tasks casually.
3. Capture the config/version used for launch, then verify the actual task/rollout
   before allowing implementation.
4. If effective tier cannot be established, mark it unverified and hold the worker
   before mutations. Intent alone is not proof of Standard mode.

Fast requires an explicit scoped user instruction. Do not spread it to unrelated
future sessions or confuse it with reasoning, task urgency or response latency.

## Worker context packet

Provide outcome/authorized phase; exact repo/worktree/base; owned files and
exclusive resources; relevant source/contracts/evidence; decisive acceptance;
model/effort/tier; bounded retries and any approved budget; output/handoff path.

Use deep reasoning where uncertainty can change the decision. Narrow a task
before increasing effort. Track accepted output, useful discoveries, latency and
total cost. Do not infer a numeric user budget from a model name or subscription.

## Startup gate

Record a provisional launch reservation, then verify:

1. The exact ID can be read; its first turn exists, is active/completed normally,
   and has the intended title/role.
2. Cwd, source and installed skill content match the intended inputs.
3. Requested model/effort are applied; label any unobservable field unverified.
4. Standard/non-Fast is established as above unless explicitly authorized otherwise.
5. Initial progress reads the contract; implementation remains held until the
   Supervisor accepts the launch internally.
6. Any specifically required permission mode is evidenced by the runtime/rollout,
   not only config text. Do not broaden permissions to pass a failed gate.

Stop wrong-setting launches before side effects, fix the cause, and create at
most one supported replacement. A missing task is not proof that earlier work
failed; inspect preserved artifacts before retrying. Workers report and stop;
the Supervisor creates authorized successors. Use cursor-based bounded waits.

## Sources

- https://developers.openai.com/api/docs/models/gpt-6-astra
- https://developers.openai.com/api/docs/guides/latest-model
- https://developers.openai.com/api/docs/models/gpt-5.6-sol
- https://learn.chatgpt.com/docs/agent-configuration/subagents

These describe capabilities, not the settings of a particular running task.
