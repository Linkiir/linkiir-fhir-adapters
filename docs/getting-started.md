# Getting started with Linkiir FHIR Adapters

## 1. Subscribe

**Settings → Catalogs → Subscribe**, then paste the repository URL:

```
https://github.com/Linkiir/linkiir-fhir-adapters
```

Public repository, so no SSH key is required. Track `main`.

## 2. Build a node from an adapter

Open a project workflow, add a node, and pick the adapter from the catalog section of the node picker. Grid copies the adapter's files into your node and records where they came from, so the node can follow later updates.

## 3. Fill in credentials

Credential fields ship empty by design. Enter yours on the node, leave **Live Mode** off, and run it once to confirm configuration and authentication before sending anything real.

## 4. Keep it up to date

**Settings → Catalogs → Check for updates** shows the incoming commit and diff before you apply it. While a node stays linked to this catalog its files are managed for you and cannot be edited locally; its configuration values stay editable throughout. Unlink a node to take ownership of its files and stop following updates.
