# `fhir_profiling` 1.0.0

FHIR resource profiling tool. Loads FHIR specification profiles from a SQLite database, lists available resources and types, and generates JSON templates with null-valued fields for any resource or complex type.

| | |
|---|---|
| **Library** | `fhir_profiling` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `fhir_profiling/fhir_profiling.lua`
- `fhir_profiling/fhir_profiling_create.lua`
- `fhir_profiling/fhir_profiling_db.lua`
- `fhir_profiling/fhir_profiling_web.lua`

## Using it

A node that pins this library gets the `fhir_profiling/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local fhir_profiling = require("fhir_profiling.fhir_profiling")
```
