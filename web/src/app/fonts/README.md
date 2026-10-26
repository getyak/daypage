# Existing DayPage web fonts

These unmodified WOFF2 files are the Latin faces returned by Google Fonts for the
existing DayPage font requests: Space Grotesk 500/700, Inter 400/500/600,
JetBrains Mono 400/500 and Fraunces 400/600 in normal and italic. They total
184,276 bytes. CSS variable names remain unchanged. Other scripts use the
existing system fallback stack.

`next/font/local` loads the checked-in assets so production builds do not depend
on Google returning file URLs compatible with the Next 16.2.6 Google loader.
The earlier build failed while parsing a remote file URL in that loader; local
assets also make future builds reproducible without a font network request.

`sources.json` records immutable source URLs, style, size and SHA-256 for each
asset. Each family's SIL Open Font License text is included alongside it:
[Google Fonts repository](https://github.com/google/fonts/tree/main/ofl).

Loader API: [Next.js Font reference](https://nextjs.org/docs/app/api-reference/components/font#local-fonts).
