# eCW Adapter

Queries an eCW FHIR server using OAuth 2.0 JWT-bearer authentication with a separate token endpoint and pushes each returned resource downstream as JSON.

| | |
|---|---|
| **Slug** | `ecw_adapter` |
| **Node type id** | `LKFHIR_ECW_ADAPTER` |
| **Node type** | source |
| **Version** | 1.0.0 |
| **Interval driven** | yes |
| **Libraries** | ecw_fhir 1.0.0 |

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| Interval | number | `60000` | How often, in milliseconds, the runtime invokes the polling script. |
| Base URL | string | `https://staging-fhir.ecwcloud.com/fhir/r4/FFBJCD/` | Root URL of the eCW FHIR endpoint. Resource paths are appended to it, so a trailing slash is expected (one is added if omitted). |
| Auth URL | string | `https://staging-oauthserver.ecwcloud.com/` | Root URL of the eCW OAuth server. The token endpoint path oauth/oauth2/token is appended to it. This is separate from the FHIR base URL. |
| Client ID | string | _(empty)_ | The client ID assigned when the app was registered with eCW. |
| Private Key Path | file_path | _(empty)_ | Absolute path to the PEM-encoded RSA private key whose public key is registered with eCW. Used to sign the RS384 JWT client assertion. |
| Key ID | string | _(empty)_ | The key identifier (kid) placed in the JWT header. Must match the key ID registered with eCW for your public key. |
| FHIR Version | list | `R4` | FHIR release to target. |
| Scopes | string | `system/Patient.read system/Medication.read system/Encounter.read` | OAuth scopes to request. Space-separated. eCW requires scopes on the token request (unlike Epic). Defaults to system/Patient.read system/Medication.read system/Encounter.read if left empty. |
| Resource Type | string | `Patient` | FHIR resource type to search on each poll, for example Patient, Encounter or Observation. |
| Search Query | string | `family=Smith&birthdate=1970-01-01` | Search parameters as a URL query string, for example family=Smith&birthdate=1970-01-01. Leave empty to search without filters. |
| Live Mode | bool | `true` | When off, FHIR requests are simulated and no data leaves the runtime. Authentication is always performed live so credential problems surface immediately. |
| Verify TLS | bool | `true` | Whether to verify the eCW server's TLS certificate. Leave on outside of local testing. |
