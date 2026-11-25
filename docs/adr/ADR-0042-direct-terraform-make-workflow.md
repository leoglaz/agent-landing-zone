# ADR-0042: Direct Terraform infrastructure workflow through Make

**Status:** Accepted for this checkout<br>
**Date:** 2026-11-18<br>
**Owners:** Agent Landing Zone maintainers

## Context

The operator requires Terraform-only infrastructure deployment using Make,
an existing Entra-authenticated state backend and an explicit per-stack key.
The previously introduced Make wrapper depended on azd and its environment
store. This checkout must not require azd or Task for this workflow.

Priorities are explicit state ownership, native locking, predictable inputs
and separation of infrastructure provisioning from application deployment.

## Alternatives considered

- Keep the azd wrapper: retains service-configuration hooks, but does not meet
  the operator's requirement to remove azd from the execution path.
- Add another workflow runner or reproduce azd hooks: increases dependencies
  and lifecycle complexity without being required for infrastructure.
- Use Make to invoke the existing Terraform root directly: meets the requested
  boundary and retains provider/module pins, but excludes application setup.
- Do not change: leaves an unwanted azd dependency.

## Decision

Make invokes Terraform init, plan, apply and output directly. Backend JSON
is ignored and contains the complete state address; a committed placeholder
example documents its shape. Ignored native tfvars contain explicit
workload inputs. Bootstrap is an alias for init, not backend creation.
Apply always generates and applies a fresh saved plan. Native state locking
stays enabled and each environment has its own Terraform data directory.

Runtime versions and the Make execution boundary do not change. The networking
ownership exception below applies equally to both providers and shared preflight.
This workflow does not claim equivalent application readiness: builds,
Foundry/Search service configuration and runtime registration are excluded.
Optional networking still requires a connected runner and appropriate DNS,
routes, Azure permissions and quotas.

## Adoption and migration

Authenticate to Azure, review the backend key, copy the example input file and
select workload group ownership explicitly. The backend must remain outside
workload teardown destinations. Bootstrap does not migrate or force-copy state.
Do not run azd and direct Terraform concurrently or switch a deployed
environment between workflows without reviewing its exact state and inputs.
Rollback restores the prior entry point without changing the state address.

### Customer-managed routing decision (2026-11-24)

The operator approved a narrower ownership exception after withdrawing the
standalone-wide no-egress relaxation. Existing VNet reuse, subnet creation
disabled and firewall creation disabled, with neither external routing input
supplied, selects customer-managed routing in both standalone and integrated
modes. Both providers omit managed firewall, route-table and default-route
resources; existing subnet associations remain untouched. Shared preflight
reports customer ownership as information, not a connectivity failure.

Alternatives were retaining the baseline (which requires a routing declaration
even for read-only reuse), or allowing all standalone no-egress deployments
(which weakens managed-network safeguards). The ownership exception preserves
those safeguards while respecting customer networking boundaries. Priorities
are zero subnet routing writes, provider parity, and unchanged explicit routing
behavior, each measured by regression contracts. Cost is limited to the
resources already selected; no additional egress resources are introduced.

Private endpoints, public-access restrictions, identities, RBAC, required
delegations and service endpoints remain unchanged. No runtime component or
data migration is required. Customers own DNS, routing, outbound connectivity
and security controls; acceptance of their declaration proves no reachability.
Deploy code and shared checks together, inspect the plan, and verify connectivity
from the intended runner before application setup. Rollback requires configuring
supported explicit routing before reverting this exception; never restore a
managed route table over customer networking merely to satisfy validation.

## Compliance verification

Stubbed CLI tests verify no azd invocation, command ordering, saved-plan use,
subscription checks, credential rejection, failure propagation and cache
isolation. Backend/interface regression tests protect the unchanged foundation.
Offline evidence does not establish deployed Azure parity or runtime readiness.
Ownership-matrix preflight tests, mocked Terraform networking plans and compiled
Bicep contract checks cover customer-managed reuse and unchanged managed egress.

## Documentation impact and review trigger

Update the root and Terraform READMEs and central Terraform operator guidance.
Revisit before adding application configuration, automated state migration,
shared/production execution or changing the root's required inputs.
Central network-isolation and deployment-configuration guidance must describe
the ownership exception. Revisit this decision if subnet writes are added to
reuse mode or if either provider changes its egress ownership contract.
