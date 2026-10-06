import "server-only";
import { and, asc, eq } from "drizzle-orm";
import { Opik, OpikSpanType as SpanType } from "opik";
import { db } from "@/lib/db/client";
import {
  agent_artifacts,
  agent_run_steps,
  agent_runs,
  memos,
  user_settings,
} from "@/lib/db/schema";
import { evaluationConfig, type EvaluationExportMode } from "./config";
import {
  claimEvaluationExport,
  completeEvaluationExport,
  failEvaluationExport,
  type LeasedEvaluationExport,
} from "./outbox";
import { pseudonymizeUser, scrubEvaluationValue } from "./privacy";

type TraceProjection = {
  id: string;
  name: string;
  startTime: Date;
  endTime?: Date;
  input: Record<string, unknown>;
  output: Record<string, unknown>;
  metadata: Record<string, unknown>;
  tags: string[];
  threadId?: string;
  errorInfo?: { exceptionType: string; message?: string; traceback: string };
  spans: Array<{
    id: string;
    name: string;
    type: "general" | "tool" | "llm" | "guardrail";
    startTime: Date;
    endTime?: Date;
    input: Record<string, unknown>;
    output: Record<string, unknown>;
    metadata: Record<string, unknown>;
    model?: string;
    usage?: Record<string, number>;
    errorInfo?: { exceptionType: string; message?: string; traceback: string };
  }>;
};

let cachedClient: Opik | null = null;
let cachedClientKey = "";

function opikClient(): Opik {
  const config = evaluationConfig();
  if (!config.configured) {
    throw new Error(
      "Evaluation export is enabled but Opik configuration is incomplete; set OPIK_API_KEY (for cloud), OPIK_PROJECT_NAME, OPIK_WORKSPACE, and EVALUATION_PSEUDONYM_SALT",
    );
  }
  const key = JSON.stringify([
    config.apiKey,
    config.apiUrl,
    config.projectName,
    config.workspaceName,
    config.environment,
  ]);
  if (!cachedClient || cachedClientKey !== key) {
    cachedClient = new Opik({
      apiKey: config.apiKey,
      ...(config.apiUrl ? { apiUrl: config.apiUrl } : {}),
      projectName: config.projectName,
      workspaceName: config.workspaceName,
      holdUntilFlush: true,
    });
    cachedClientKey = key;
  }
  return cachedClient;
}

function stringField(value: unknown, key: string): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const field = (value as Record<string, unknown>)[key];
  return typeof field === "string" ? field : undefined;
}

function traceThreadId(triggerSnapshot: unknown): string | undefined {
  return stringField(triggerSnapshot, "thread_id") ?? stringField(triggerSnapshot, "conversation_id");
}

function exportedErrorMessage(
  error: Record<string, unknown>,
  mode: EvaluationExportMode,
  fallback: string,
): string {
  if (mode === "metadata_only") return fallback;
  const message = typeof error.message === "string" ? error.message : fallback;
  const scrubbed = scrubEvaluationValue(message, mode);
  return typeof scrubbed === "string" ? scrubbed.slice(0, 2_000) : fallback;
}

function stepType(step: {
  tool_key: string | null;
  step_key: string;
  receipt: unknown;
}): "general" | "tool" | "llm" | "guardrail" {
  if (step.tool_key) return SpanType.Tool;
  const receipt = (step.receipt ?? {}) as Record<string, unknown>;
  const details = receipt.details as Record<string, unknown> | undefined;
  if (typeof details?.model === "string" || /understand|synthesize|review|plan/.test(step.step_key)) {
    return SpanType.Llm;
  }
  return SpanType.General;
}

async function effectivePrivacyMode(
  requested: EvaluationExportMode,
  userId: string,
): Promise<EvaluationExportMode> {
  if (requested !== "full_content_opt_in") return requested;
  const [row] = await db
    .select({ settings: user_settings.settings })
    .from(user_settings)
    .where(eq(user_settings.user_id, userId))
    .limit(1);
  const settings = (row?.settings ?? {}) as Record<string, unknown>;
  const evaluation = settings.evaluation as Record<string, unknown> | undefined;
  return evaluation?.full_content_opt_in === true ? requested : "metadata_only";
}

export async function buildOpikTraceProjection(input: {
  runId: string;
  requestedMode: EvaluationExportMode;
}): Promise<TraceProjection> {
  const [run] = await db
    .select()
    .from(agent_runs)
    .where(eq(agent_runs.id, input.runId))
    .limit(1);
  if (!run) throw new Error(`Evaluation Run not found: ${input.runId}`);
  const mode = await effectivePrivacyMode(input.requestedMode, run.user_id);
  const [steps, artifacts, memoRows] = await Promise.all([
    db
      .select()
      .from(agent_run_steps)
      .where(eq(agent_run_steps.run_id, run.id))
      .orderBy(asc(agent_run_steps.ordinal)),
    db
      .select()
      .from(agent_artifacts)
      .where(eq(agent_artifacts.run_id, run.id))
      .orderBy(asc(agent_artifacts.created_at)),
    run.memo_id
      ? db
          .select({ id: memos.id, body: memos.body, content_hash: memos.content_hash })
          .from(memos)
          .where(and(eq(memos.id, run.memo_id), eq(memos.user_id, run.user_id)))
          .limit(1)
      : Promise.resolve([]),
  ]);
  const memo = memoRows[0];
  const config = evaluationConfig();
  const skillSnapshot = (run.skill_snapshot ?? {}) as Record<string, unknown>;
  const agentSnapshot = (run.agent_snapshot ?? {}) as Record<string, unknown>;
  const modelPolicy = agentSnapshot.modelPolicy as Record<string, unknown> | undefined;
  const totalTokensIn = steps.reduce((total, step) => total + step.tokens_in, 0);
  const totalTokensOut = steps.reduce((total, step) => total + step.tokens_out, 0);
  const contentInput = mode === "metadata_only"
    ? undefined
    : scrubEvaluationValue(
        {
          memo: memo?.body,
          trigger: run.trigger_snapshot,
        },
        mode,
      );
  const contentOutput = mode === "metadata_only"
    ? undefined
    : scrubEvaluationValue(
        {
          summary: run.summary,
          artifacts: artifacts.map((artifact) => ({
            id: artifact.id,
            kind: artifact.kind,
            status: artifact.status,
            payload: artifact.payload,
            body_md: artifact.body_md,
          })),
        },
        mode,
      );
  const error = (run.error ?? {}) as Record<string, unknown>;
  return {
    id: run.id,
    name: `daypage.${String(skillSnapshot.key ?? run.trigger_type)}`,
    startTime: run.started_at ?? run.created_at,
    endTime: run.completed_at ?? undefined,
    input: {
      trigger_type: run.trigger_type,
      trigger_ref_hash: run.trigger_ref ? `present:${run.trigger_ref.length}` : null,
      memo_revision: run.memo_revision,
      content_hash: memo?.content_hash ?? null,
      ...(contentInput !== undefined ? { content: contentInput } : {}),
    },
    output: {
      status: run.status,
      artifact_kinds: artifacts.map((artifact) => artifact.kind),
      ...(contentOutput !== undefined ? { content: contentOutput } : {}),
    },
    metadata: {
      daypage_run_id: run.id,
      user_pseudonym: pseudonymizeUser(run.user_id, config.pseudonymSalt),
      skill_version_id: run.skill_version_id,
      skill_checksum: run.skill_checksum,
      skill_version: skillSnapshot.version ?? null,
      model: modelPolicy?.preferredModel ?? null,
      shadow: run.shadow,
      canonical: run.is_canonical,
      attempt: run.attempt,
      privacy_mode: mode,
      tokens_in: totalTokensIn,
      tokens_out: totalTokensOut,
      artifact_count: artifacts.length,
    },
    tags: [
      `env:${config.environment}`,
      `trigger:${run.trigger_type}`,
      `status:${run.status}`,
      run.shadow ? "shadow" : "canonical",
      `privacy:${mode}`,
    ],
    ...(traceThreadId(run.trigger_snapshot) ? { threadId: traceThreadId(run.trigger_snapshot) } : {}),
    ...(run.status === "failed"
      ? {
          errorInfo: {
            exceptionType: typeof error.name === "string" ? error.name : "AgentRunError",
            message: exportedErrorMessage(error, mode, "Agent Run failed"),
            traceback: "",
          },
        }
      : {}),
    spans: steps.map((step) => {
      const receipt = (step.receipt ?? {}) as Record<string, unknown>;
      const details = (receipt.details ?? {}) as Record<string, unknown>;
      const stepError = (step.error ?? {}) as Record<string, unknown>;
      return {
        id: step.id,
        name: step.step_key,
        type: stepType(step),
        startTime: step.started_at ?? step.created_at,
        endTime: step.completed_at ?? undefined,
        input: { hash: step.input_hash },
        output: { hash: step.output_hash, status: step.status },
        metadata: {
          ordinal: step.ordinal,
          tool_key: step.tool_key,
          duration_ms: step.duration_ms,
          details:
            mode === "metadata_only"
              ? { field_names: Object.keys(details).sort().slice(0, 50) }
              : scrubEvaluationValue(details, mode),
        },
        ...(typeof details.model === "string" ? { model: details.model } : {}),
        usage: {
          prompt_tokens: step.tokens_in,
          completion_tokens: step.tokens_out,
          total_tokens: step.tokens_in + step.tokens_out,
        },
        ...(step.status === "failed"
          ? {
              errorInfo: {
                exceptionType: typeof stepError.name === "string" ? stepError.name : "AgentStepError",
                message: exportedErrorMessage(stepError, mode, "Agent step failed"),
                traceback: "",
              },
            }
          : {}),
      };
    }),
  };
}

async function exportTrace(item: LeasedEvaluationExport, client: Opik): Promise<string> {
  const projection = await buildOpikTraceProjection({
    runId: item.entity_id,
    requestedMode: item.privacy_mode as EvaluationExportMode,
  });
  const trace = client.trace({
    id: projection.id,
    name: projection.name,
    startTime: projection.startTime,
    endTime: projection.endTime,
    input: projection.input,
    output: projection.output,
    metadata: projection.metadata,
    tags: projection.tags,
    threadId: projection.threadId,
    errorInfo: projection.errorInfo,
  });
  for (const span of projection.spans) {
    trace.span({
      id: span.id,
      name: span.name,
      type: span.type,
      startTime: span.startTime,
      endTime: span.endTime,
      input: span.input,
      output: span.output,
      metadata: span.metadata,
      model: span.model,
      usage: span.usage,
      errorInfo: span.errorInfo,
    });
  }
  await client.flush({ silent: true });
  return trace.data.id;
}

async function exportScore(item: LeasedEvaluationExport, client: Opik): Promise<string> {
  if (!item.run_id) throw new Error(`Score export ${item.id} has no Run`);
  const payload = item.payload as Record<string, unknown>;
  const scores = item.entity_type === "feedback"
    ? (payload.scores as Array<{ name: string; value: number; reason?: string }> | undefined)
    : [
        {
          name: String(payload.name ?? "evaluation"),
          value: Number(payload.value ?? 0),
          ...(typeof payload.reason === "string" ? { reason: payload.reason } : {}),
        },
      ];
  if (!scores?.length) throw new Error(`Score export ${item.id} has no scores`);
  client.logTracesFeedbackScores(
    scores.map((score) => ({
      id: item.run_id as string,
      name: score.name,
      value: score.value,
      ...(score.reason ? { reason: score.reason } : {}),
    })),
  );
  await client.flush({ silent: true });
  return item.run_id;
}

async function processEvaluationExport(item: LeasedEvaluationExport): Promise<string> {
  const client = opikClient();
  if (item.entity_type === "trace" && item.operation === "upsert") {
    return exportTrace(item, client);
  }
  if (
    (item.entity_type === "feedback" || item.entity_type === "evaluation_result") &&
    item.operation === "score"
  ) {
    return exportScore(item, client);
  }
  throw new Error(`Unsupported evaluation export ${item.entity_type}:${item.operation}`);
}

export async function drainEvaluationExports(limit = 20): Promise<{
  processed: number;
  failures: number;
}> {
  const config = evaluationConfig();
  if (config.exportMode === "off") return { processed: 0, failures: 0 };
  let processed = 0;
  let failures = 0;
  for (; processed < limit; processed += 1) {
    const item = await claimEvaluationExport();
    if (!item) break;
    try {
      const externalId = await processEvaluationExport(item);
      await completeEvaluationExport(item, externalId);
    } catch (error) {
      failures += 1;
      await failEvaluationExport(item, error);
    }
  }
  return { processed, failures };
}
