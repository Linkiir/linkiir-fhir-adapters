# FHIR Resource Creator

Maps inbound patient data onto a FHIR R4 Patient template, strips unused null fields, and pushes the clean resource downstream as JSON.

| | |
|---|---|
| **Slug** | `fhir_resource_creator` |
| **Node type id** | `LKFHIR_FHIR_RESOURCE_CREATOR` |
| **Node type** | transform |
| **Version** | 1.0.0 |
| **Interval driven** | no |
| **Libraries** | fhir_resource 1.0.0 |

## Samples

De-identified messages you can run the node against:

- `samples/patient_input.json`
