# `athena_health` 1.0.0

Athena Health client. Handles client_credentials OAuth authentication and provides search, create and request helpers for both the proprietary REST API and the FHIR R4 API. Copy the athena_health/ folder into a node and add it to package.path.

| | |
|---|---|
| **Library** | `athena_health` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `athena_health/athena_health.lua`
- `athena_health/athena_health_auth.lua`
- `athena_health/athena_health_http.lua`
- `athena_health/athena_health_token.lua`

## Using it

A node that pins this library gets the `athena_health/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local athena_health = require("athena_health.athena_health")
```
