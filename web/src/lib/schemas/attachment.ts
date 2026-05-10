import { z } from "zod";

export const ALLOWED_MIME_TYPES = [
  "audio/m4a",
  "audio/mp4",
  "image/jpeg",
  "image/png",
  "image/heic",
  "image/heif",
  "application/pdf",
] as const;

export const MAX_SIZE_BYTES = 50 * 1024 * 1024; // 50 MB

export const AttachmentKindSchema = z.enum(["audio", "photo", "file"]);

export const SignAttachmentSchema = z.object({
  memo_id: z.string().uuid("memo_id must be a UUID"),
  kind: AttachmentKindSchema,
  mime_type: z.enum(ALLOWED_MIME_TYPES, {
    error: `mime_type must be one of: ${ALLOWED_MIME_TYPES.join(", ")}`,
  }),
  size_bytes: z
    .number()
    .int()
    .positive()
    .max(MAX_SIZE_BYTES, `size_bytes must be <= ${MAX_SIZE_BYTES} (50 MB)`),
});

export const FinalizeAttachmentSchema = z.object({
  memo_id: z.string().uuid("memo_id must be a UUID"),
  storage_key: z.string().min(1, "storage_key is required"),
  kind: AttachmentKindSchema,
  filename: z.string().optional(),
  mime_type: z.string().optional(),
  size_bytes: z.number().int().positive().optional(),
  duration_sec: z.number().positive().optional(),
  transcript: z.string().optional(),
  ocr_text: z.string().optional(),
  exif: z.record(z.unknown()).optional(),
});

export type SignAttachmentInput = z.infer<typeof SignAttachmentSchema>;
export type FinalizeAttachmentInput = z.infer<typeof FinalizeAttachmentSchema>;
