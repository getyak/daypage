import { z } from "zod";

export const MemoTypeSchema = z.enum(["text", "url", "voice", "photo", "file"]);
export const IngestModeSchema = z.enum(["light", "full"]);
export const CompileStatusSchema = z.enum(["pending", "running", "done", "failed"]);
export const OriginSchema = z.enum(["ios", "web", "api"]);

export const LocationSchema = z.object({
  lat: z.number().optional(),
  lng: z.number().optional(),
  address: z.string().optional(),
  city: z.string().optional(),
  country: z.string().optional(),
}).passthrough();

export const WeatherSchema = z.object({
  condition: z.string().optional(),
  temp_c: z.number().optional(),
  humidity: z.number().optional(),
  city: z.string().optional(),
}).passthrough();

export const CreateMemoSchema = z.object({
  type: MemoTypeSchema.optional().default("text"),
  body: z.string().min(1, "Body is required"),
  created_at: z.string().datetime().optional(),
  location: LocationSchema.optional(),
  weather: WeatherSchema.optional(),
  device: z.string().optional(),
  source_url: z.string().url().optional(),
  origin: OriginSchema.optional().default("web"),
  ingest_mode: IngestModeSchema.optional().default("light"),
  vault_path: z.string().optional(),
  idempotency_key: z.string().max(255).optional(),
  source: z.string().optional().default("web"),
  device_id: z.string().optional(),
  mood: z.string().optional(),
  word_count: z.number().int().min(0).optional(),
  attachments: z
    .array(
      z.object({
        kind: z.enum(["audio", "photo", "file"]),
        storage_key: z.string(),
        filename: z.string().optional(),
        mime_type: z.string().optional(),
        size_bytes: z.number().int().positive().optional(),
        duration_sec: z.number().optional(),
        transcript: z.string().optional(),
        ocr_text: z.string().optional(),
        exif: z.record(z.string(), z.unknown()).optional(),
      })
    )
    .optional(),
});

export const PatchMemoSchema = z.object({
  type: MemoTypeSchema.optional(),
  body: z.string().min(1).optional(),
  location: LocationSchema.nullable().optional(),
  weather: z.string().nullable().optional(),
  device: z.string().nullable().optional(),
  source_url: z.string().url().nullable().optional(),
  ingest_mode: IngestModeSchema.optional(),
  compile_status: CompileStatusSchema.optional(),
  pinned_at: z.string().datetime().nullable().optional(),
}).strict();

export const ListMemosQuerySchema = z.object({
  cursor: z.string().optional(),
  since: z.string().datetime().optional(),
  compile_status: CompileStatusSchema.optional(),
  limit: z.coerce.number().int().min(1).max(100).optional().default(20),
});

export const BulkMemoItemSchema = CreateMemoSchema.extend({
  id: z.string().uuid("Each memo must have a client-generated UUID"),
  updated_at: z.string().datetime().optional(),
});

export const BulkMemosSchema = z.object({
  memos: z
    .array(BulkMemoItemSchema)
    .min(1, "At least one memo required")
    .max(100, "Maximum 100 memos per bulk request"),
});

export type CreateMemoInput = z.infer<typeof CreateMemoSchema>;
export type PatchMemoInput = z.infer<typeof PatchMemoSchema>;
export type ListMemosQuery = z.infer<typeof ListMemosQuerySchema>;
export type BulkMemoItem = z.infer<typeof BulkMemoItemSchema>;
export type BulkMemosInput = z.infer<typeof BulkMemosSchema>;
