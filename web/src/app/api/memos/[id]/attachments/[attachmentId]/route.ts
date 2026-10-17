import { NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { supabaseMemoStore, type QueryBuilderLike } from "@/lib/memos/store";
import {
  handleAttachmentRequest,
  type AttachmentProxyUser,
  type ObjectFetchArgs,
} from "@/lib/memos/attachment-proxy";
import { encodeStorageKeyPath } from "@/lib/memos/media";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ATTACHMENTS_BUCKET = "memo-attachments";

type Params = { params: Promise<{ id: string; attachmentId: string }> };

// Private Storage fetch for ONE object. The bucket, base URL and API key live
// only here on the server. `redirect: "manual"` fails closed so the verified
// user's Bearer token can never be forwarded to another host.
async function fetchPrivateObject(args: ObjectFetchArgs): Promise<Response> {
  const baseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const apiKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!baseUrl || !apiKey) throw new Error("Storage is not configured");

  const url = `${baseUrl.replace(/\/+$/, "")}/storage/v1/object/${ATTACHMENTS_BUCKET}/${encodeStorageKeyPath(
    args.key,
  )}`;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${args.accessToken}`,
    apikey: apiKey,
    "Accept-Encoding": "identity",
  };
  if (args.range) headers.Range = args.range;

  return fetch(url, {
    method: args.method,
    headers,
    signal: args.signal,
    redirect: "manual",
    cache: "no-store",
  });
}

type SupabaseServerClient = Awaited<ReturnType<typeof createClient>>;

async function authenticate(
  supabase: SupabaseServerClient,
): Promise<AttachmentProxyUser | null> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const {
    data: { session },
  } = await supabase.auth.getSession();
  const accessToken = session?.access_token;
  if (!accessToken) return null;
  return { id: user.id, accessToken };
}

// GET/HEAD /api/memos/[id]/attachments/[attachmentId] — authenticated,
// same-origin streaming proxy for the memo's private Storage object. The
// request never supplies an object key or URL: keys come from trusted DB
// metadata validated against the verified owner uid.
async function handle(request: NextRequest, { params }: Params) {
  const { id, attachmentId } = await params;
  const supabase = await createClient();
  return handleAttachmentRequest(
    request,
    { memoId: id, attachmentId },
    {
      authenticate: () => authenticate(supabase),
      store: supabaseMemoStore({
        from: (table) => supabase.from(table) as unknown as QueryBuilderLike,
      }),
      fetchObject: fetchPrivateObject,
    },
  );
}

export async function GET(request: NextRequest, context: Params) {
  return handle(request, context);
}

export async function HEAD(request: NextRequest, context: Params) {
  return handle(request, context);
}
