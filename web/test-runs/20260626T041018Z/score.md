# UX Audit: / (landing) — 2026-06-26T04:10:18Z

## Audit method
Code-based analysis (dev server returns 500 due to missing DATABASE_URL in CI env;
auth middleware crashes on every request). Scored against the 6-dimension rubric by
reading `src/app/page.tsx`, `src/app/login/page.tsx`, and the full `globals.css`
design-token system.

## Route context
`GET /` → `redirect("/home")` → `(app)/layout.tsx` → `redirect("/login")` for
unauthenticated users. The **login page** (`/login`) is therefore the effective landing
experience for new visitors.

---

## Dimension scores (pre-improvement)

| # | Dimension | Weight | Raw | Weighted |
|---|-----------|--------|-----|---------|
| 1 | Visual consistency | 20% | 55 | 11.0 |
| 2 | Information hierarchy & readability | 20% | 65 | 13.0 |
| 3 | Accessibility | 15% | 62 | 9.3 |
| 4 | Responsive | 15% | 78 | 11.7 |
| 5 | Micro-interactions & motion | 15% | 38 | 5.7 |
| 6 | Edge states | 15% | 22 | 3.3 |

**Total: 54.0 / 100**

---

## Dimension breakdown

### 1. Visual consistency (55/100)
- ✓ Uses design-system tokens: `bg-bg-warm`, `ds-h1`, `ds-body-md`, `btn btn--primary/secondary`
- ✓ `--radius-sm: 6px` is defined in globals.css; buttons get correct rounding
- ✗ Card is plain `<div class="card">` — no visual brand presence
- ✗ No logo / brand mark; "DayPage" as raw `ds-h1` text only
- ✗ Apple button lacks Apple glyph — nothing visually differentiates it from a generic button
- ✗ Input `rounded-[var(--radius-sm)]` uses raw Tailwind arbitrary value instead of design-token class

### 2. Information hierarchy (65/100)
- ✓ `<h1>DayPage</h1>` clear top-level heading
- ✓ Subtitle "Your personal AI knowledge system"
- ✗ Value proposition is generic; no explanation of the capture→compile→wiki pipeline
- ✗ No feature bullets to explain what DayPage actually does
- ✗ No visual separation (OR divider) between the two auth methods
- ✗ Apple sign-in and magic link at equal visual weight; Apple should be primary CTA

### 3. Accessibility (62/100)
- ✓ Email inputs have `aria-label` ✓
- ✓ `required` attribute on email fields ✓
- ✓ Semantic `<form>` elements ✓
- ✗ No `aria-live` region for auth feedback (success/error)
- ✗ No visible focus indicator on email input (plain `outline: none` + `focus:ring-2` Tailwind)
- ✗ No `id` on email input / no explicit `<label>` element (only aria-label)
- ✗ Two separate forms with separate tab stops creates confusing keyboard navigation
- ✗ No skip-to-content or landmark `role="main"`
- ✗ Error states from auth failures not surfaced to screen readers

### 4. Responsive (78/100)
- ✓ `min-h-screen flex items-center justify-center` works for centering on all viewports
- ✓ `w-full max-w-sm` constrains width on desktop
- ✓ `flex flex-col gap-6` natural stacking on mobile
- ✗ No media-query tests for very small viewports (iPhone SE: 375px)
- ✗ No safe-area padding for notch/home bar (mobile web)

### 5. Micro-interactions (38/100)
- ✓ Button hover states defined in globals.css (`.btn--primary:hover`, `.btn--secondary:hover`)
- ✓ Button transitions defined (100ms ease-out)
- ✗ No loading state on Apple sign-in button while OAuth redirect is initiated
- ✗ No loading state on magic-link button while email is being sent
- ✗ No submission feedback at all — user sees nothing until a full-page redirect or error page

### 6. Edge states (22/100)
- ✗ No loading state on form submission
- ✗ No success state after magic link is sent ("check your email")
- ✗ No in-page error state for auth failures (invalid email, SMTP error, rate limit)
- ✗ No network-error handling
- ✗ No keyboard shortcut (Enter to submit) for the Apple form

---

## Planned improvements (to reach ≥ 90/100)

1. **Create `login/actions.ts`** — server actions with proper error/success returns
2. **Create `login/EmailSignInForm.tsx`** — "use client" with `useActionState`, loading + success + error states
3. **Update `login/page.tsx`** — brand mark, Apple glyph, feature bullets, OR divider, landmark markup
4. **Add CSS to globals.css** — `.login-*` component classes, dark mode, responsive

## Projected score (post-improvement)

| # | Dimension | Weight | Raw | Weighted |
|---|-----------|--------|-----|---------|
| 1 | Visual consistency | 20% | 92 | 18.4 |
| 2 | Information hierarchy | 20% | 91 | 18.2 |
| 3 | Accessibility | 15% | 90 | 13.5 |
| 4 | Responsive | 15% | 91 | 13.65 |
| 5 | Micro-interactions | 15% | 88 | 13.2 |
| 6 | Edge states | 15% | 92 | 13.8 |

**Projected: 90.75 / 100**
