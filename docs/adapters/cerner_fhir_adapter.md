# Cerner FHIR Adapter

Queries a Cerner FHIR server using SMART backend services JWT-bearer authentication and pushes each returned resource downstream as JSON.

| | |
|---|---|
| **Slug** | `cerner_fhir_adapter` |
| **Node type id** | `LKFHIR_CERNER_FHIR_ADAPTER` |
| **Node type** | source |
| **Version** | 1.0.0 |
| **Interval driven** | yes |
| **Libraries** | cerner_fhir 1.0.0 |

## Configuration

| Field | Type | Default | Notes |
|---|---|---|---|
| Interval | number | `60000` | How often, in milliseconds, the runtime invokes the polling script. |
| Base URL | string | _(empty)_ | The base Cerner FHIR endpoint for your tenant. This must match the tenant used when issuing OAuth tokens and should not include resource paths like '/Patient'. A trailing slash is added if missing. |
| Client ID | string | _(empty)_ | The OAuth client identifier assigned to your Cerner application on CernerCentral. |
| Private Key Path | file_path | _(empty)_ | Absolute path to the PEM-encoded RSA private key whose public key is registered in the JWKS on the CernerCentral System Account. Read at authentication time and never copied into the node config. |
| Key ID | string | _(empty)_ | The kid (Key ID) identifying which public key in your JWKS Cerner should use to verify the JWT signature. Placed in the JWT header. |
| Scopes | string | `system/Patient.read` | SMART on FHIR OAuth scopes requested when obtaining an access token, space-separated. Cerner requires scopes on the token request. |
| Resource Type | string | `Patient` | FHIR resource type to search on each poll, for example Patient, Encounter or Observation. |
| Search Query | string | `family=smart&given=joe&_count=5` | Search parameters as a URL query string, for example family=Smith&birthdate=1970-01-01. Leave empty to search without filters. |
| Live Mode | bool | `true` | When off, FHIR requests are simulated and no data leaves the runtime, which is useful while wiring up a workflow. Authentication is always performed live so credential problems surface immediately. |
| Verify TLS | bool | `true` | Whether to verify the Cerner server's TLS certificate. Leave on outside of local testing against a proxy. |
