# Look in code base for more

# Attack paths

# Service principals 
In Azure Entra ID, a service principal is flagged as misconfigured when its identity, credentials, or permissions violate security or governance baselines enforced by Entra ID, Defender for Cloud, or Identity Secure Score. The determination is rule-based, not behavioral.

Core determinants:

1. Credentials
	•	Expired client secrets or certificates.
	•	Secrets without expiration.
	•	Multiple active credentials without rotation discipline.
	•	Credentials unused for extended periods but still valid.

2. Permissions
	•	Overprivileged API permissions (e.g. Directory.ReadWrite.All, RoleManagement.ReadWrite.Directory) without demonstrated need.
	•	Application permissions granted where delegated permissions would suffice.
	•	Permissions granted but never used.
	•	Permissions granted directly instead of via managed identity or workload identity federation.

3. Ownership and Governance
	•	No assigned owners.
	•	Owners are disabled users, guests, or external accounts.
	•	Excessive number of owners.
	•	Owners without appropriate administrative roles.

4. Exposure Surface
	•	Multi-tenant app registrations when single-tenant is sufficient.
	•	Redirect URIs that are overly broad, wildcarded, or unused.
	•	Public client flows enabled unnecessarily.
	•	Legacy authentication flows enabled.

5. Identity Type Misuse
	•	Client secret–based auth used instead of certificate or federated credentials.
	•	Managed identity available but not used.
	•	Workload identity federation not used for CI/CD scenarios.

6. Lifecycle Hygiene
	•	Service principals tied to deleted app registrations.
	•	Orphaned enterprise applications.
	•	Applications not used for long periods but still enabled.
	•	Test or temporary apps left in production tenants.

7. Policy and Security Baselines
	•	Non-compliance with Entra ID Secure Score controls.
	•	Violations detected by Microsoft Defender for Identity / Defender for Cloud Apps.
	•	Conditional Access exclusions applied to service principals unnecessarily.

In short: misconfigured = excessive privilege, weak or unmanaged credentials, unnecessary exposure, missing ownership, or stale lifecycle state, as evaluated against Entra ID security controls.