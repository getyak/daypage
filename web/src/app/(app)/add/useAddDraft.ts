'use client';

import { useState, useEffect, useCallback } from 'react';

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

  useEffect(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) {
        const parsed: AddDraft = JSON.parse(raw);
        setDraftState(parsed);
        setRestoredAt(parsed.savedAt);
      }
    } catch {
      // ignore malformed storage data
    }
  }, []);

  const saveDraft = useCallback((next: AddDraft) => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
    } catch {
      // ignore storage quota errors
    }
    setDraftState(next);
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
