# Release 0.6.16

Decision: EXTEND the existing verified publisher, package builder and capability manifest. Publish reviewed companion updates without changing official runtime binaries or private state. Update the release identity and download references; broaden the existing CI and publisher test entry points to include every existing test suite rather than introducing a second release path. Keep current compatibility and prerelease boundaries, package signatures, extracted native canary, remote hash verification and rollback behavior.

CI follow-up: unittest discovery must import scripts without launching local integration environments. Keep official-runtime execution behind its script entry point; load the adaptive boundary's aiohttp dependency only when explicitly executing that integration script. The publisher still invokes packaged integration acceptance explicitly. No application payload change is needed.
