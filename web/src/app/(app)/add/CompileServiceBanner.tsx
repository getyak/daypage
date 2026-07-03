"use client";

// CompileServiceBanner — single-source pipeline health strip for /add.
//
// Before v9 refactor, every MemoRow in CompileQueue showed the raw string
// "编译服务未连接（运行 pnpm run dev:inngest）" whenever Inngest was down.
// That's ops debug leaked into a museum-restraint page, and it repeats up
// to 20 times per screen. v9 collapses it into ONE amber banner at the
// top of /add, matching /home's `.home-pipeline-warn` treatment. The
// MemoRow subtitle drops the string entirely; the pending pill (see
// CompileQueue.tsx) still says QUEUED so users can still triage rows.

import { useQuery } from "@tanstack/react-query";
import { AlertCircle } from "lucide-react";

interface CompileStatusResponse {
  connected: boolean;
}

async function fetchCompileServiceStatus(): Promise<CompileStatusResponse> {
  const res = await fetch("/api/compile/status");
  if (!res.ok) throw new Error("Failed to fetch compile status");
  return res.json() as Promise<CompileStatusResponse>;
}

export function CompileServiceBanner() {
  const { data } = useQuery<CompileStatusResponse>({
    queryKey: ["compile", "service-status"],
    queryFn: fetchCompileServiceStatus,
    staleTime: 60_000,
  });
  // Optimistic: only show the banner once we're SURE the pipeline is down.
  // A missing/failed status probe stays quiet — no false alarms in staging.
  if (data?.connected !== false) return null;

  return (
    <div className="ds-add-pipeline-warn" role="status" data-testid="compile-service-banner">
      <AlertCircle size={14} strokeWidth={2} aria-hidden="true" />
      <span>编译服务未连接 —— 新记录会保存，但暂不会被编译。</span>
    </div>
  );
}
