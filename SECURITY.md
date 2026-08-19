# Security Policy

## Supported versions

Until the first stable release, only the latest tagged release is supported. Security fixes are not backported to older development snapshots.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's **Security → Report a vulnerability** form for this repository. Include the affected version, macOS and Apple Container versions, the deployment mode, reproduction steps, and the potential impact. Remove passwords, Pi-hole session identifiers, private DNS queries, and other household network data before submitting.

If private vulnerability reporting is not enabled yet, contact the maintainer privately and wait for a secure reporting channel rather than publishing exploit details. You should receive an acknowledgement within seven days.

Adputate's `bugreport` command deliberately omits credentials, endpoint addresses, DNS queries, and service logs. Review its generated text before sharing it anyway.
