# FHIR Profiling Tools

Serves a browser UI listing available FHIR resources and types, and returns JSON templates for any requested resource.

| | |
|---|---|
| **Slug** | `fhir_profiling_tools` |
| **Node type id** | `LKFHIR_FHIR_PROFILING_TOOLS` |
| **Node type** | source |
| **Version** | 1.0.0 |
| **Interval driven** | no |
| **Libraries** | fhir_profiling 1.0.0 |

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| Route Path | string | `fhir` | The URL path this endpoint listens on. |
| Worker Count | number | `1` | The number of parallel Lua VM instances handling concurrent requests. |
| FHIR Version | list | `4.0.1` | The FHIR specification version to load profiles for. |
| Refresh | bool | `false` | When enabled, the profile database is rebuilt on next request. Disable after the initial load to avoid repeated processing. |
| Specifications Path | string | _(empty)_ | Absolute path to the Specifications directory containing FHIR profile JSON files and the SQLite database. If empty, defaults to the Specifications/ folder inside the node directory. |

## Samples

De-identified messages you can run the node against:

- `samples/get_patient.txt`
- `samples/get_unknown.txt`
- `samples/root_page.txt`
