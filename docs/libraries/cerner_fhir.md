# `cerner_fhir` 1.0.0

Cerner FHIR client. Handles SMART backend services authentication (signed JWT client assertion with kid header) and provides search, read, create, update and operation helpers. Copy the cerner_fhir/ folder into a node and add it to package.path.

| | |
|---|---|
| **Library** | `cerner_fhir` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `cerner_fhir/cerner_fhir.lua`
- `cerner_fhir/cerner_fhir_auth.lua`
- `cerner_fhir/cerner_fhir_http.lua`
- `cerner_fhir/cerner_fhir_jwt.lua`
- `cerner_fhir/cerner_fhir_token.lua`

## Using it

A node that pins this library gets the `cerner_fhir/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local cerner_fhir = require("cerner_fhir.cerner_fhir")
```
