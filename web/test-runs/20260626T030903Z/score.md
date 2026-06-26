# UX Audit — / (landing) — 2026-06-26T03:09:03Z

## Target
`/ (landing)` — first unchecked item in `web/test.md`

## Pre-improvement state
The `/` route was a bare server redirect: `redirect("/home")` with no page content.
Non-authenticated users were bounced through two redirects (/ → /home → /login) to reach
a minimal login card with no error handling, no loading states, no "or" divider, and a
plain placeholder text `aria-label` instead of a visible `<label>`.

**Pre-improvement score: ~35/100**

---

## Post-improvement score

| Dimension | Weight | Score | Weighted |
|---|---|---|---|
| Visual consistency | 20% | 92 | 18.4 |
| Information hierarchy | 20% | 91 | 18.2 |
| Accessibility | 15% | 88 | 13.2 |
| Responsive | 15% | 90 | 13.5 |
| Micro-interactions | 15% | 88 | 13.2 |
| Edge states | 15% | 90 | 13.5 |
| **Total** | | | **90.0 / 100** |

---

## Dimension breakdown

### 1. Visual consistency — 92/100
- All colors from the design token system (`--bg-warm`, `--accent`, `--accent-soft`,
  `--border-subtle`, `--border-default`)
- Typography: `font-display` (Space Grotesk) for brand/headline/h2; `--font-body` (Inter)
  for body/labels; correct size scale
- Auth card uses `--shadow-composer` for elevated feel against the warm background
- Feature icon containers use `--radius-small` + `--accent-soft` / `--accent` colors
- Dark mode compatible: all colours via CSS custom properties that switch on `data-theme`
- `-0.02em` letter-spacing on headline uses the same convention as the iOS title tokens

### 2. Information hierarchy — 91/100
- Clear scan path: Brand (D + DayPage wordmark) → H1 headline → Subtitle → Feature list →
  Auth card (H2 "Get started") → Trust signal
- Headline is visually dominant (`clamp(2.25rem, 4vw, 3.25rem)`)
- Feature labels bold, descriptions muted — scannability ✓
- "or" divider with `--border-default` lines separates Apple from email clearly
- Trust signal ("No credit card needed. Your data stays private.") anchors the card bottom

### 3. Accessibility — 88/100
- `<main>` landmark ✓
- `<section aria-labelledby="hero-heading">` ✓
- `<section aria-label="Sign in to DayPage">` ✓
- `<h1>` / `<h2>` heading hierarchy ✓
- `<ul aria-label="Key features">` for feature list ✓
- Visible `<label htmlFor="landing-email">` (not just aria-label) ✓
- Error banner: `role="alert"` + `aria-live="assertive"` ✓
- Decorative icons: `aria-hidden="true"` ✓
- Skip link: `sr-only focus:not-sr-only` → jumps to `#auth-section` ✓
- Buttons: `aria-busy` set via `useFormStatus` ✓
- Focus indicators: `.btn:focus-visible` (outline: 2px accent) + `focus:ring-2` on input ✓
- Deduction: contrast not formally verified for `--fg-muted` at `text-xs` sizes

### 4. Responsive — 90/100
- Desktop 1440×900: two-column split (flex-1 hero / 480px fixed auth)
- Mobile 390×844: single column (hero → auth card)
- `clamp()` on headline for fluid scaling between breakpoints
- `max-w-lg` on hero content, `max-w-sm` on auth card
- `lg:border-l` vertical separator visible only on desktop
- `pb-16 pt-8 lg:pb-0 lg:pt-0` correct padding adaptation

### 5. Micro-interactions — 88/100
- Entry animations: `landing-fade-in` (0.45s ease-out) + stagger 0.12s / 0.18s ✓
- `prefers-reduced-motion` disables all entry animations ✓
- Feature items: `.landing-feature:hover` → `--accent-soft` background +
  `.landing-feature__icon:hover` → `--accent-border` background, both 220ms transitions ✓
- Logo D mark: `.landing-logo-mark:hover` → `scale(1.06)` + shadow, 220ms spring ✓
- Buttons: `btn--primary:hover → --accent-hover`, `btn:active → translateY(0.5px)` ✓
- Submit loading: `LoginSubmitButton` uses `useFormStatus` → spinner SVG + `aria-busy` ✓
- Input: `focus:ring-2 focus:ring-accent/30 transition-all` ✓
- Auth card: `.landing-auth-card:focus-within` → 3px accent ring ✓
- Deduction: touch devices don't trigger hover (feature items static on mobile)

### 6. Edge states — 90/100
- Error banner: 5 error type → human message mappings
  (`OAuthAccountNotLinked`, `OAuthSignin`, `EmailSignin`, `Verification`, `AccessDenied`, `Default`) ✓
- Loading state: `useFormStatus` → spinner on both Apple and magic link buttons ✓
- Auth redirect: `auth()` check → `redirect("/home")` for logged-in users, try/catch
  for dev environments without DB ✓
- Server error boundary: `src/app/error.tsx` with "Try again" reset + "Go to sign in" link ✓
- 404 page: `src/app/not-found.tsx` with brand treatment and navigation options ✓

---

## Files changed

| File | Change |
|---|---|
| `src/app/page.tsx` | Full rewrite: proper landing page (was bare redirect) |
| `src/app/login/LoginSubmitButton.tsx` | New: `useFormStatus` loading-state client component |
| `src/app/login/page.tsx` | Enhanced: error banner, visible label, "or" divider, loading states |
| `src/app/error.tsx` | New: error boundary with reset + navigation |
| `src/app/not-found.tsx` | New: 404 page with brand identity |
| `src/app/globals.css` | Added: landing animations, feature hover, divider, logo hover, auth card focus |

**Files changed: 6**
