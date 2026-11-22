# Convex backend

DriVio's Convex deployment holds live data only. Trip archives, which this document
used to describe as stored in Convex, now live in each application's own Neon
project: payloads in its Object Storage, metadata in the `drivio` schema of its database. Uploads keep the same contract
(`docs/BINARY_FORMAT.md`) and go to each application's Neon function.

See [APPS.md](APPS.md) for how applications are mounted on the deployment and how
live and long-term data are split.
