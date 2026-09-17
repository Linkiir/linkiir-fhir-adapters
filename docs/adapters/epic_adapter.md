# EPIC Adapter

Queries an Epic FHIR server using OAuth 2.0 JWT-bearer authentication and pushes each returned resource downstream as JSON.

| | |
|---|---|
| **Slug** | `epic_adapter` |
| **Node type id** | `LKFHIR_EPIC_ADAPTER` |
| **Node type** | source |
| **Version** | 1.0.0 |
| **Interval driven** | yes |
| **Libraries** | epic_fhir 1.0.0 |

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| Interval | number | `60000` | How often, in milliseconds, the runtime invokes the polling script. |
| Base URL | string | `https://fhir.epic.com/interconnect-fhir-oauth/` | Root URL of the Epic Interconnect FHIR endpoint. The token endpoint and /api/FHIR paths are appended to it, so a trailing slash is expected (one is added if omitted). |
| Client ID | string | _(empty)_ | The non-production or production client ID assigned when the app was registered on the Epic App Orchard / open.epic. |
| Private Key Path | file_path | _(empty)_ | Absolute path to the PEM-encoded RSA private key whose public key is registered with Epic. Used to sign the RS384 JWT client assertion; it is read at authentication time and never copied into the node config. |
| FHIR Version | list | `R4` | FHIR release to target. Becomes the version segment of /api/FHIR/<version>/. |
| Resource Type | string | `Patient` | FHIR resource type to search on each poll, for example Patient, Encounter or Observation. |
| Search Query | string | `family=Lufhir&given=Sakiko&birthdate=1994-07-22` | Search parameters as a URL query string, for example family=Smith&birthdate=1970-01-01. Leave empty to search without filters. Epic requires at least one identifying parameter for most resource types. |
| Live Mode | bool | `true` | When off, FHIR requests are simulated and no data leaves the runtime, which is useful while wiring up a workflow. Authentication is always performed live so credential problems surface immediately. |
| Verify TLS | bool | `true` | Whether to verify the Epic server's TLS certificate. Leave on outside of local testing against a proxy. |
