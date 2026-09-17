# Linkiir FHIR Adapters

Adapters Linkiir Grid speaks over FHIR: FHIR-native EHR and EMR APIs, managed FHIR servers, and FHIR authoring tools.

A **catalog** is a package of adapter content that one Linkiir Grid publishes and other grids subscribe to. Subscribing adds these adapters to your grid without a product upgrade.

| | |
|---|---|
| **Catalog id** | `lkfhir` |
| **Publisher** | Linkiir Inc |
| **Adapters** | 7 |
| **Libraries** | 7 |
| **Documentation** | [https://help.linkiir.com/docs/catalogs/](https://help.linkiir.com/docs/catalogs/) |

---

## Subscribe

In Grid, open **Settings → Catalogs → Subscribe** and paste this URL:

```
https://github.com/Linkiir/linkiir-fhir-adapters
```

| Field | Value |
|---|---|
| **URL** | the address above |
| **Ref** | `main` |
| **SSH private key** | leave blank — this is a public repository, cloned anonymously |
| **Install name** | `linkiir-fhir-adapters` |

Use the install name exactly as given. Grid records it on every node built from this catalog, so a consistent name keeps a node's origin readable when you contact support.

Subscribing requires the **Manage catalogs** permission (Administration tier). Full instructions, including how to review an update before applying it, are in [the Catalogs documentation](https://help.linkiir.com/docs/catalogs/).

## Adapters

| Adapter | Type | Trigger | Version | Node type id |
|---|---|---|---|---|
| **Athena Adapter** | source | interval | 1.0.0 | `LKFHIR_ATHENA_ADAPTER` |
| **Cerner FHIR Adapter** | source | interval | 1.0.0 | `LKFHIR_CERNER_FHIR_ADAPTER` |
| **eCW Adapter** | source | interval | 1.0.0 | `LKFHIR_ECW_ADAPTER` |
| **EPIC Adapter** | source | interval | 1.0.0 | `LKFHIR_EPIC_ADAPTER` |
| **FHIR Profiling Tools** | source | inbound request | 1.0.0 | `LKFHIR_FHIR_PROFILING_TOOLS` |
| **FHIR Resource Creator** | transform | on message | 1.0.0 | `LKFHIR_FHIR_RESOURCE_CREATOR` |
| **ModMed Adapter** | source | interval | 1.0.0 | `LKFHIR_MODMED_ADAPTER` |

### Athena Adapter

Queries Athena Health using client_credentials OAuth 2.0 authentication and pushes matching patient resources downstream as JSON. Supports both the proprietary REST API and the FHIR R4 API.

`LKFHIR_ATHENA_ADAPTER` · source node · version 1.0.0 · 9 configuration fields · library `athena_health` 1.0.0

Credentials required: **Client Secret**. These ship empty — see [Credentials](#credentials).

### Cerner FHIR Adapter

Queries a Cerner FHIR server using SMART backend services JWT-bearer authentication and pushes each returned resource downstream as JSON.

`LKFHIR_CERNER_FHIR_ADAPTER` · source node · version 1.0.0 · 10 configuration fields · library `cerner_fhir` 1.0.0

### eCW Adapter

Queries an eCW FHIR server using OAuth 2.0 JWT-bearer authentication with a separate token endpoint and pushes each returned resource downstream as JSON.

`LKFHIR_ECW_ADAPTER` · source node · version 1.0.0 · 12 configuration fields · library `ecw_fhir` 1.0.0

### EPIC Adapter

Queries an Epic FHIR server using OAuth 2.0 JWT-bearer authentication and pushes each returned resource downstream as JSON.

`LKFHIR_EPIC_ADAPTER` · source node · version 1.0.0 · 9 configuration fields · library `epic_fhir` 1.0.0

### FHIR Profiling Tools

Serves a browser UI listing available FHIR resources and types, and returns JSON templates for any requested resource.

`LKFHIR_FHIR_PROFILING_TOOLS` · source node · version 1.0.0 · 5 configuration fields · library `fhir_profiling` 1.0.0

### FHIR Resource Creator

Maps inbound patient data onto a FHIR R4 Patient template, strips unused null fields, and pushes the clean resource downstream as JSON.

`LKFHIR_FHIR_RESOURCE_CREATOR` · transform node · version 1.0.0 · 0 configuration fields · library `fhir_resource` 1.0.0

### ModMed Adapter

Queries a ModMed FHIR server using password/refresh-token authentication with an API key and pushes each returned resource downstream as JSON.

`LKFHIR_MODMED_ADAPTER` · source node · version 1.0.0 · 9 configuration fields · library `modmed_fhir` 1.0.0

Credentials required: **Password**, **API Key**. These ship empty — see [Credentials](#credentials).

## Libraries

Shared Lua modules the adapters above depend on. A node pins the exact version it uses, and published versions are immutable, so several can sit side by side.

| Library | Version | Used by |
|---|---|---|
| `athena_health` | 1.0.0 | Athena Adapter |
| `cerner_fhir` | 1.0.0 | Cerner FHIR Adapter |
| `ecw_fhir` | 1.0.0 | eCW Adapter |
| `epic_fhir` | 1.0.0 | EPIC Adapter |
| `fhir_profiling` | 1.0.0 | FHIR Profiling Tools |
| `fhir_resource` | 1.0.0 | FHIR Resource Creator |
| `modmed_fhir` | 1.0.0 | ModMed Adapter |

### `athena_health` 1.0.0

Athena Health client. Handles client_credentials OAuth authentication and provides search, create and request helpers for both the proprietary REST API and the FHIR R4 API. Copy the athena_health/ folder into a node and add it to package.path.

Modules: `athena_health.lua`, `athena_health_auth.lua`, `athena_health_http.lua`, `athena_health_token.lua`

### `cerner_fhir` 1.0.0

Cerner FHIR client. Handles SMART backend services authentication (signed JWT client assertion with kid header) and provides search, read, create, update and operation helpers. Copy the cerner_fhir/ folder into a node and add it to package.path.

Modules: `cerner_fhir.lua`, `cerner_fhir_auth.lua`, `cerner_fhir_http.lua`, `cerner_fhir_jwt.lua`, `cerner_fhir_token.lua`

### `ecw_fhir` 1.0.0

eCW FHIR client. Handles JWT client-credentials authentication with a separate token endpoint and provides search, read, create, parameters and bulk export helpers. Copy the ecw_fhir/ folder into a node and add it to package.path.

Modules: `ecw_fhir.lua`, `ecw_fhir_auth.lua`, `ecw_fhir_http.lua`, `ecw_fhir_jwt.lua`, `ecw_fhir_token.lua`

### `epic_fhir` 1.0.0

Epic FHIR client. Handles SMART backend services authentication (signed JWT client assertion) and provides search, read, create, update and operation helpers. Copy the epic_fhir/ folder into a node and add it to package.path.

Modules: `epic_fhir.lua`, `epic_fhir_auth.lua`, `epic_fhir_http.lua`, `epic_fhir_jwt.lua`, `epic_fhir_token.lua`

### `fhir_profiling` 1.0.0

FHIR resource profiling tool. Loads FHIR specification profiles from a SQLite database, lists available resources and types, and generates JSON templates with null-valued fields for any resource or complex type.

Modules: `fhir_profiling.lua`, `fhir_profiling_create.lua`, `fhir_profiling_db.lua`, `fhir_profiling_web.lua`

### `fhir_resource` 1.0.0

FHIR Patient resource builder. Parses inbound patient data, maps it onto a FHIR R4 Patient template, strips JSON nulls from unused fields, and returns the clean serialised resource. No network or authentication.

Modules: `fhir_resource.lua`, `fhir_resource_clean.lua`

### `modmed_fhir` 1.0.0

ModMed FHIR client. Handles password and refresh-token authentication with an API key and provides search, read and create helpers. Copy the modmed_fhir/ folder into a node and add it to package.path.

Modules: `modmed_fhir.lua`, `modmed_fhir_auth.lua`, `modmed_fhir_http.lua`, `modmed_fhir_token.lua`

## Credentials

Every adapter here ships with its credential fields **empty**, by design. Password fields are encrypted with your own grid's key, so a value shipped from this repository could not be decrypted on your machine. Enter yours on the node after you build it.

Two fields appear on most adapters:

| Field | What it does |
|---|---|
| **Live Mode** | When off, requests are prepared and logged but never sent. Use it to confirm configuration and authentication before touching a live system. |
| **Verify TLS** | Verifies the server's certificate. Leave on. Turn it off only against a local service with a self-signed certificate. |

## Versions and updates

| | |
|---|---|
| **Adapters** | Versioned by the `version` field on each adapter. A change that does not move the version forward is rejected, so one version always means one specific set of files. |
| **Libraries** | Immutable. A published version is never edited; a fix ships as a new version. Nodes pinned to an older version are undisturbed by an update. |

Grid shows you the incoming commit and diff before applying an update. Release notes for every Linkiir catalog adapter and library are published at [help.linkiir.com](https://help.linkiir.com/docs/catalogs/).

## Repository layout

```
catalog.json                              catalog manifest
nodes/<slug>/node_config.json             an adapter definition
nodes/<slug>/*.lua                        its scripts
nodes/<slug>/samples/                     de-identified test messages
libraries/<name>/<version>/library.json   a published library version
libraries/<name>/<version>/<name>/*.lua   its modules
```

The layout matches Grid's own on-disk layout, so a pull applies no transform.

## Other Linkiir catalogs

| Catalog | Covers |
|---|---|
| **linkiir-fhir-adapters** _(this one)_ | FHIR adapters and FHIR tooling |
| [linkiir-ehr-adapters](https://github.com/Linkiir/linkiir-ehr-adapters) | EHR and practice management over proprietary APIs, openEHR |
| [linkiir-interop-adapters](https://github.com/Linkiir/linkiir-interop-adapters) | HL7 v2, C-CDA, IHE, HIE, public health, engine migration |
| [linkiir-payer-adapters](https://github.com/Linkiir/linkiir-payer-adapters) | X12 EDI, clearinghouses, payer APIs, pharmacy |
| [linkiir-diagnostics-adapters](https://github.com/Linkiir/linkiir-diagnostics-adapters) | labs and LIS, imaging and PACS, devices |
| [linkiir-data-adapters](https://github.com/Linkiir/linkiir-data-adapters) | relational and NoSQL databases, warehouses, BI |
| [linkiir-transport-adapters](https://github.com/Linkiir/linkiir-transport-adapters) | object storage, file transport, message brokers |
| [linkiir-ai-adapters](https://github.com/Linkiir/linkiir-ai-adapters) | AI and LLM services |
| [linkiir-notification-adapters](https://github.com/Linkiir/linkiir-notification-adapters) | chat, SMS, voice, email, paging |
| [linkiir-business-adapters](https://github.com/Linkiir/linkiir-business-adapters) | CRM, ERP, ITSM, HR, identity, scheduling |

## Documentation and support

Product documentation lives at **[help.linkiir.com](https://help.linkiir.com/docs/catalogs/)** — how catalogs work, subscribing and reviewing updates, building nodes from catalog adapters, and offline delivery. This repository holds the adapter content itself; it is not the documentation site.

For a question about a specific adapter, quote its node type id.

## License

Copyright © Linkiir Inc. All rights reserved.

This source is published so Linkiir Grid customers can read, audit and run it. It is **not** open source, and no open-source licence is granted. Use of this content is governed by your agreement with Linkiir Inc covering Linkiir Grid. For licensing enquiries, contact Linkiir.

