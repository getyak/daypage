# Private App information preparation

This is the private pre-filing stage of ADR-0033. It binds only
`127.0.0.1:18080` on the purchased Shanghai ECS. It does not publish DNS,
open a security group, expose a website or claim App filing approval.

Use the exact reviewed `DayPageLocal/Resources/app-info.json` bytes from the
same source revision as the iOS client. Package that file with these scripts
and record SHA256 hashes before transport. Install through the owner's normal
server-management channel, after confirming the exact ECS target and ownership.
The optional package installation uses the existing Alibaba OS repositories;
it does not start or replace an existing nginx service.

```sh
bash install-private.sh ./app-info.json
bash verify-private.sh <reviewed-payload-sha256>
systemctl restart daypage-app-information.service
bash verify-private.sh <reviewed-payload-sha256>
```

The standalone nginx instance uses its own configuration, runtime directory and
unit. The payload is public read-only text. Only GET at the exact JSON path is
served; other methods, paths and Host values are rejected. Access logging is off
in this exact configuration; critical startup/runtime errors can go to journald,
and infrastructure metadata processing is not eliminated by that setting.

Do not silently overwrite an earlier installation: the installer refuses existing
owned paths/listeners. Preserve an installation receipt before preparing an update.
An interrupted installation may leave inert owned files; inspect the exact stage
before recovery. To pause this preparation, stop and disable only
`daypage-app-information.service`, retaining the files and content hash for recovery.

Before public operation, separately complete App filing and the reviewed
DNS/valid-TLS/public-HTTPS deployment. Replace the private listener with the reviewed
production configuration, verify the same content hash and method/path boundaries,
then validate the actual iOS request and user-visible behavior. Do not release a new
binary on the strength of loopback checks alone. Existing GitHub privacy/support
URLs remain the public store documents until an approved replacement is ready.
