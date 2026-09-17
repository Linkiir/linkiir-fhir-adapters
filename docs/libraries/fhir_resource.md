# `fhir_resource` 1.0.0

FHIR Patient resource builder. Parses inbound patient data, maps it onto a FHIR R4 Patient template, strips JSON nulls from unused fields, and returns the clean serialised resource. No network or authentication.

| | |
|---|---|
| **Library** | `fhir_resource` |
| **Version** | 1.0.0 |
| **Immutable** | yes — a fix ships as a new version directory |

## Modules

- `fhir_resource/fhir_resource.lua`
- `fhir_resource/fhir_resource_clean.lua`

## Using it

A node that pins this library gets the `fhir_resource/` folder copied in beside its script. Add it to `package.path` and require the entry module:

```lua
local fhir_resource = require("fhir_resource.fhir_resource")
```
