-- Store sticker images outside the messages table so each chat message remains small.
-- The application server uploads and removes objects with its service-role key.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'chat-stickers',
  'chat-stickers',
  TRUE,
  2097152,
  ARRAY['image/png', 'image/jpeg', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "Read public chat stickers" ON storage.objects;
CREATE POLICY "Read public chat stickers"
  ON storage.objects FOR SELECT
  TO anon, authenticated
  USING (bucket_id = 'chat-stickers');
