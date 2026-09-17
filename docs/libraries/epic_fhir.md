# `epic_fhir` 1.0.0

Epic FHIR client. Handles SMART backend services authentication (signed JWT client assertion) and provides search, read, create, update and operation helpers. Copy the epic_fhir/ folder into a node and add it to package.path.

| | |
|---|---|
| **Library** | `epic_fhir` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `epic_fhir/epic_fhir.lua`
- `epic_fhir/epic_fhir_auth.lua`
- `epic_fhir/epic_fhir_http.lua`
- `epic_fhir/epic_fhir_jwt.lua`
- `epic_fhir/epic_fhir_token.lua`

## Using it

A node that pins this library gets the `epic_fhir/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local epic_fhir = require("epic_fhir.epic_fhir")
```
