# `ecw_fhir` 1.0.0

eCW FHIR client. Handles JWT client-credentials authentication with a separate token endpoint and provides search, read, create, parameters and bulk export helpers. Copy the ecw_fhir/ folder into a node and add it to package.path.

| | |
|---|---|
| **Library** | `ecw_fhir` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `ecw_fhir/ecw_fhir.lua`
- `ecw_fhir/ecw_fhir_auth.lua`
- `ecw_fhir/ecw_fhir_http.lua`
- `ecw_fhir/ecw_fhir_jwt.lua`
- `ecw_fhir/ecw_fhir_token.lua`

## Using it

A node that pins this library gets the `ecw_fhir/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local ecw_fhir = require("ecw_fhir.ecw_fhir")
```
