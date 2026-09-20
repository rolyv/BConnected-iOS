# BConnected Chat — iPhone pilot

Personal fork owned by [rolyv](https://github.com/rolyv), independent of Signal and GAIL/Lula. Original Signal copyright and AGPLv3 notices remain in place.

## What runs today

Open `BConnectedPilot/BConnectedPilot.xcodeproj`. This separate native target implements invitation-based alumni applications, name/graduation-year approval status, and a directory preview with Groups, DMs and Stories navigation. It calls the BConnected community API in `roly-dev`; it is **not yet an encrypted messenger**. Preview mode contains clearly labelled fictional data. DMs, Stories, group creation, and chat joining do not send messages in this target.

The full Signal target has initial BConnected display-name/icon/bundle-prefix changes and 10,000-member group-size defaults. Its build intentionally fails until the independent messaging stack is configured. Do not bypass this guard to connect a large-group fork to Signal production.

## Remaining integration

- Fork/configure libsignal network endpoints, TLS trust, and service public parameters. `Net.Environment` currently exposes only Signal staging/production; changing TSConstants alone is insufficient.
- Provision Signal server, storage/group service, queues/datastores, registration, attachments, push, and required dependencies.
- Enforce alumni approval on messaging registration and authenticated operations, including suspension of existing sessions; a client-only approval gate is insufficient.
- Bind community identities to Signal account identifiers without allowing client-supplied account substitution.
- Integrate Groups/My groups/Discover and a real DMs-only thread query into the Signal UI; preserve existing end-to-end encryption.
- Create an admin-send-only all-alumni group, apply the storage-service group cap, and publish the matching remote-config values.
- Validate 8,000-member joins, sender-key distribution, fanout, offline delivery, membership changes, attachments, device memory, and push volume before making any capacity claim.
- Add the personal Apple Developer team and APNs configuration for device/TestFlight builds. Use a separate association bundle ID for the public release.

## Group cap

`RemoteConfigManager.swift` defaults both group-size flags to 10,000, allowing headroom over the requested 8,000. Values supplied by the fork's remote-config service can override these defaults. The companion `BConnected-Storage` fork contains the server configuration fragment. This is a configuration change, not proof that groups of that size work reliably.
