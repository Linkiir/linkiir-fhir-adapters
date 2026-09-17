# Linkiir FHIR Adapters

Anything Linkiir speaks over FHIR: FHIR-native EHR and EMR APIs, managed FHIR servers, and FHIR authoring tools.

**Catalog id:** `lkfhir` — every node template in this catalog carries a `LKFHIR_` node type id.
**Published adapters:** 7 &nbsp;•&nbsp; **Published libraries:** 7

---

## Subscribe

In Grid, go to **Settings → Catalogs → Subscribe** and paste:

```
https://github.com/Linkiir/linkiir-fhir-adapters
```

This is a public repository, so Grid clones it anonymously and no SSH key is needed. Leave **Ref** at `main` to track the latest published content.

Install it under the name **`linkiir-fhir-adapters`**. The install name is recorded on every node built from this catalog, so keeping it consistent makes a node's origin readable in support.

Subscribing needs the **Manage catalogs** permission (Administration tier).

## Published adapters

| Adapter | Slug | Node type | Node type id | Version | Libraries |
|---|---|---|---|---|---|
| Athena Adapter | `athena_adapter` | source | `LKFHIR_ATHENA_ADAPTER` | 1.0.0 | athena_health 1.0.0 |
| Cerner FHIR Adapter | `cerner_fhir_adapter` | source | `LKFHIR_CERNER_FHIR_ADAPTER` | 1.0.0 | cerner_fhir 1.0.0 |
| eCW Adapter | `ecw_adapter` | source | `LKFHIR_ECW_ADAPTER` | 1.0.0 | ecw_fhir 1.0.0 |
| EPIC Adapter | `epic_adapter` | source | `LKFHIR_EPIC_ADAPTER` | 1.0.0 | epic_fhir 1.0.0 |
| FHIR Profiling Tools | `fhir_profiling_tools` | source | `LKFHIR_FHIR_PROFILING_TOOLS` | 1.0.0 | fhir_profiling 1.0.0 |
| FHIR Resource Creator | `fhir_resource_creator` | transform | `LKFHIR_FHIR_RESOURCE_CREATOR` | 1.0.0 | fhir_resource 1.0.0 |
| ModMed Adapter | `modmed_adapter` | source | `LKFHIR_MODMED_ADAPTER` | 1.0.0 | modmed_fhir 1.0.0 |

## Published libraries

| Library | Version | Purpose |
|---|---|---|
| `athena_health` | 1.0.0 | Athena Health client. Handles client_credentials OAuth authentication and provides search, create and request helpers for both the proprietary REST API and the FHIR R4 API. Copy the athena_health/ folder into a node and add it to package.path. |
| `cerner_fhir` | 1.0.0 | Cerner FHIR client. Handles SMART backend services authentication (signed JWT client assertion with kid header) and provides search, read, create, update and operation helpers. Copy the cerner_fhir/ folder into a node and add it to package.path. |
| `ecw_fhir` | 1.0.0 | eCW FHIR client. Handles JWT client-credentials authentication with a separate token endpoint and provides search, read, create, parameters and bulk export helpers. Copy the ecw_fhir/ folder into a node and add it to package.path. |
| `epic_fhir` | 1.0.0 | Epic FHIR client. Handles SMART backend services authentication (signed JWT client assertion) and provides search, read, create, update and operation helpers. Copy the epic_fhir/ folder into a node and add it to package.path. |
| `fhir_profiling` | 1.0.0 | FHIR resource profiling tool. Loads FHIR specification profiles from a SQLite database, lists available resources and types, and generates JSON templates with null-valued fields for any resource or complex type. |
| `fhir_resource` | 1.0.0 | FHIR Patient resource builder. Parses inbound patient data, maps it onto a FHIR R4 Patient template, strips JSON nulls from unused fields, and returns the clean serialised resource. No network or authentication. |
| `modmed_fhir` | 1.0.0 | ModMed FHIR client. Handles password and refresh-token authentication with an API key and provides search, read and create helpers. Copy the modmed_fhir/ folder into a node and add it to package.path. |

## Roadmap

| Adapter | Node type | Connects to | Status |
|---|---|---|---|
| HAPI / OmniVera FHIR Adapter | source | HAPI FHIR and Smile OmniVera | Next |
| FHIR Destination | transform | any FHIR server (create/update/transaction) | Planned |
| FHIR Bulk Export | source | FHIR $export NDJSON | Planned |
| Epic on FHIR | source | Epic public FHIR surface | Planned |
| Azure Health Data Services / AWS HealthLake / Google Cloud Healthcare | source, destination | managed FHIR servers | Planned |
| FHIR Validator | transform | profile and IG validation | Planned |
| FHIR Terminology | transform | $lookup, $validate-code, $translate | Planned |

Status meanings: **Next** is in active development, **Planned** is scoped but not started. See [the Integration Network](https://linkiir.com/network/) for the full adapter list and where each one stands.

## Configuration and credentials

Every adapter ships with its credential fields **empty**, and that is deliberate. Password fields are encrypted with each grid's own key, so a value shipped from here could not decrypt on your machine — it would fail with an error blaming your key. Fill them in on the node after you build it.

Two fields appear on most adapters and are worth knowing:

- **Live Mode** — when off, requests are prepared and logged but never sent. Use it to prove configuration before touching a real system.
- **Verify TLS** — leave on. Turn it off only against a local service with a self-signed certificate.

## Support and status

Adapters here are **Beta** unless the roadmap table says otherwise: they work and run somewhere, but the template is still being finished, so expect a Linkiir engineer alongside you on a first deployment. **GA** means the template is hardened and running across multiple customers.

Every adapter has a named owner at Linkiir who maintains it. For a problem with a specific adapter, quote its node type id.

## Versioning

- **Adapters** are versioned by the `version` field in `node_config.json`. A change that does not move the version forward is refused by the validator.
- **Library versions are immutable.** A published `libraries/<name>/<version>/` directory is never edited; a fix ships as a new version directory. Several versions sit side by side and each node pins the one it uses, so updating this catalog cannot disturb a node pinned to an older library.

Before applying an update, Grid shows you the incoming commit and diff. Read [CHANGELOG.md](CHANGELOG.md) for what changed and why.

## Repository layout

```
catalog.json                              the manifest Grid validates
nodes/<slug>/node_config.json             an adapter's definition
nodes/<slug>/*.lua                        its scripts
nodes/<slug>/samples/                     de-identified test messages
libraries/<name>/<version>/library.json   a published library version
libraries/<name>/<version>/<name>/*.lua   its modules
```

The layout is identical to Grid's own on-disk layout, so a pull needs no transform.

---

Published by Linkiir Inc. Part of the [Linkiir catalog set](https://github.com/Linkiir?q=adapters) — see [the Catalogs documentation](https://help.linkiir.com/docs/catalogs/) for how catalogs reach a grid.
