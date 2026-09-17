# ModMed Adapter

Queries a ModMed FHIR server using password/refresh-token authentication with an API key and pushes each returned resource downstream as JSON.

| | |
|---|---|
| **Slug** | `modmed_adapter` |
| **Node type id** | `LKFHIR_MODMED_ADAPTER` |
| **Node type** | source |
| **Version** | 1.0.0 |
| **Interval driven** | yes |
| **Libraries** | modmed_fhir 1.0.0 |

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| Interval | number | `60000` | How often, in milliseconds, the runtime invokes the polling script. |
| Base URL | string | _(empty)_ | Root URL of the ModMed FHIR endpoint. The token path (ws/oauth2/grant) and FHIR path (fhir/v2/) are appended to it, so a trailing slash is expected (one is added if omitted). |
| Username | string | _(empty)_ | ModMed account username used for the initial password grant. |
| Password | password | _(empty — set on the node)_ | ModMed account password used for the initial password grant. |
| API Key | password | _(empty — set on the node)_ | The x-api-key value sent on every request, including the token exchange. |
| Resource Type | string | `Patient` | FHIR resource type to search on each poll, for example Patient, Encounter or Observation. |
| Search Query | string | `_count=20` | Search parameters as a URL query string, for example _count=20&family=Smith. Leave empty to search without filters. |
| Live Mode | bool | `true` | When off, FHIR requests are simulated and no data leaves the runtime. Authentication is always performed live so credential problems surface immediately. |
| Verify TLS | bool | `true` | Whether to verify the ModMed server's TLS certificate. Leave on outside of local testing against a proxy. |
