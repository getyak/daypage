# GET-369 implementation and verification plan

1. Add focused failing tests for note-tool scope/identities and both tool-call dialects; implement bounded read-only runtime and structured sources.
2. Add focused failing tests for speech channel persistence, endpoint/secret isolation, OpenAI-compatible and ElevenLabs request/response behavior; implement Speech core and native configuration/playback.
3. Integrate scoped opt-in tools, attachment text extraction, source navigation, explicit save-result action and speech controls into current views; preserve capture drafts and conversation leases.
4. Add native journeys and HTTP/audio fixtures. Validate core and recovery contracts serially; use hosted isolated native signing/UI workflow under local resource pause.
5. Independent reviewer checks final diff for storage safety, tool scope, credentials, cancellations, persistence and UI recovery. Fix material findings, then rerun impacted gates.
6. Link PR to GET-369 and GitHub #961, verify exact-head CI. Avoid unintended binary publication when landing: establish existing server-side release opt-out behavior before merge; otherwise keep reviewable PR ready and record the precise release boundary.

Review focus: disabled note access cannot call tools; namespace duplicates; channel endpoint edits never reuse keys; saved draft survives TTS/Agent errors; cancelled or truncated calls cannot execute; invalid audio is never accepted as preview success.

