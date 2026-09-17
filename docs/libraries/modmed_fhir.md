# `modmed_fhir` 1.0.0

ModMed FHIR client. Handles password and refresh-token authentication with an API key and provides search, read and create helpers. Copy the modmed_fhir/ folder into a node and add it to package.path.

| | |
|---|---|
| **Library** | `modmed_fhir` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `modmed_fhir/modmed_fhir.lua`
- `modmed_fhir/modmed_fhir_auth.lua`
- `modmed_fhir/modmed_fhir_http.lua`
- `modmed_fhir/modmed_fhir_token.lua`

## Using it

A node that pins this library gets the `modmed_fhir/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local modmed_fhir = require("modmed_fhir.modmed_fhir")
```
