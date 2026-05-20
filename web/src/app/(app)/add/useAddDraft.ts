'use client';

import { useState, useEffect, useCallback, useRef } from 'react';

const STORAGE_KEY = 'codex.add.draft.v1';

type DraftMode = 'text' | 'url' | 'photo' | 'file';

export interface AddDraft {
  text: string;
  mode: DraftMode;
  attachmentRef: string | null;
  savedAt: string;
}

interface UseAddDraftReturn {
  draft: AddDraft | null;
  setDraft: (draft: AddDraft) => void;
  saveDraft: (draft: AddDraft) => void;
  clearDraft: () => void;
  restoredAt: string | null;
}

export function useAddDraft(): UseAddDraftReturn {
  const [draft, setDraftState] = useState<AddDraft | null>(null);
  const [restoredAt, setRestoredAt] = useState<string | null>(null);
  const syncTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let localDraftFound = false;
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed: AddDraft = JSON.parse(raw);
        // eslint-disable-next-line react-hooks/set-state-in-effect
        setDraftState(parsed);
        // eslint-disable-next-line react-hooks/set-state-in-effect
        setRestoredAt(parsed.savedAt);
        localDraftFound = true;
      }
    } catch {
      // ignore malformed storage data
    }

    if (process.env.NEXT_PUBLIC_CODEX_DRAFT_SYNC === 'true') {
      if (!localDraftFound) {
        // fetch from server only if no local draft
        fetch('/api/drafts/add')
          .then(r => r.ok ? r.json() : null)
          .then((serverDraft: AddDraft | null) => {
            if (serverDraft?.text) {
              setDraftState(serverDraft);
              setRestoredAt(serverDraft.savedAt);
              try {
                localStorage.setItem(STORAGE_KEY, JSON.stringify(serverDraft));
              } catch { /* ignore */ }
            }
          })
          .catch(() => { /* ignore network errors */ });
      }
    }
  }, []);

  const saveDraft = useCallback((next: AddDraft) => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
    } catch {
      // ignore storage quota errors
    }
    setDraftState(next);

    if (process.env.NEXT_PUBLIC_CODEX_DRAFT_SYNC === 'true') {
      if (syncTimerRef.current) clearTimeout(syncTimerRef.current);
      syncTimerRef.current = setTimeout(() => {
        fetch('/api/drafts/add', {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(next),
        }).catch(() => { /* ignore sync errors */ });
      }, 1500);
    }
  }, []);

  const setDraft = useCallback(
    (next: AddDraft) => {
      saveDraft(next);
    },
    [saveDraft],
  );

  const clearDraft = useCallback(() => {
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {
      // ignore
    }
    setDraftState(null);
    setRestoredAt(null);
  }, []);

  return { draft, setDraft, saveDraft, clearDraft, restoredAt };
}
