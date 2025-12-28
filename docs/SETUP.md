# Setup Index

Use the guide that matches your environment:

- Oracle Cloud (production): `docs/ORACLE.md`
- macOS (local): `docs/MACOS.md`
- Linux (local): `docs/LINUX.md`
- Windows (local): `docs/WINDOWS.md`

## Common Notes

- Production ingest keys are enforced via `on_publish`.
- Local config is minimal and does not enforce ingest keys.

## Streaming Flow (Pick One)

Recommended:

```
OBS -> Oracle ingest -> (restream) YouTube/Facebook/Twitch
```

Reason: one upload from your internet, most stable.

Local relay (optional):

```
OBS -> localhost -> (restream) YouTube + Oracle ingest
```

Warning: uses one upload per destination from your home internet.
