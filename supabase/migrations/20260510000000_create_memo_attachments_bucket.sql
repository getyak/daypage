-- Create private storage bucket for memo attachments (US-014)
-- Private: no public access; clients use signed URLs for upload/download

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'memo-attachments',
  'memo-attachments',
  false,
  52428800, -- 50 MB
  ARRAY[
    'audio/m4a',
    'audio/mp4',
    'image/jpeg',
    'image/png',
    'image/heic',
    'image/heif',
    'application/pdf'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- RLS: only the authenticated user who owns the object may read/write
-- Storage path format: {user_id}/{memo_id}/{uuid}.{ext}

CREATE POLICY "memo_attachments_insert"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'memo-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "memo_attachments_select"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'memo-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "memo_attachments_delete"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'memo-attachments'
  AND (storage.foldername(name))[1] = auth.uid()::text
);
