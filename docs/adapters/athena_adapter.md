# Athena Adapter

Queries Athena Health using client_credentials OAuth 2.0 authentication and pushes matching patient resources downstream as JSON. Supports both the proprietary REST API and the FHIR R4 API.

| | |
|---|---|
| **Slug** | `athena_adapter` |
| **Node type id** | `LKFHIR_ATHENA_ADAPTER` |
| **Node type** | source |
| **Version** | 1.0.0 |
| **Interval driven** | yes |
| **Libraries** | athena_health 1.0.0 |

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| Interval | number | `60000` | How often, in milliseconds, the runtime invokes the polling script. |
| Base URL | string | `https://api.platform.athenahealth.com/` | Root URL of the Athena Health API platform. The token endpoint and API paths are appended to it. Use https://api.preview.platform.athenahealth.com/ for sandbox. A trailing slash is added if omitted. |
| Client ID | string | _(empty)_ | The OAuth client identifier assigned to your application on the Athena developer portal. |
| Client Secret | password | _(empty — set on the node)_ | The OAuth client secret paired with the Client ID. Never stored in plaintext. |
| Scopes | string | `athena/service/Athenanet.MDP.* system/Patient.read` | OAuth scopes requested when obtaining an access token, space-separated. |
| Practice ID | string | `1128700` | The Athena practice identifier used in proprietary REST API paths (v1/<practice_id>/...). |
| Search Query | string | `firstname=John` | Search parameters as a URL query string, for example firstname=John&lastname=Smith. Leave empty to search without filters. |
| Live Mode | bool | `true` | When off, API requests are simulated and no data leaves the runtime, which is useful while wiring up a workflow. Authentication is always performed live so credential problems surface immediately. |
| Verify TLS | bool | `true` | Whether to verify the Athena server's TLS certificate. Leave on outside of local testing against a proxy. |
