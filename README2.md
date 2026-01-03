The Workflow I Understand:
🎯 Triggers → 🎼 Orchestrator → ⚡ 3 Activity Functions → 💾 Storage & 🗄️ Data Layers
Key Flow:
Timer (6 hours) or Manual HTTP triggers the Durable Orchestrator
Step 1: CollectEntraUsers queries Graph API and streams JSONL to Blob Storage (2-3 min)
Step 2: IndexInCosmosDB performs delta detection and parallel writes to 3 Cosmos containers (6-8 min)
Step 3: TestAIFoundry validates AI connectivity (optional, non-blocking)
The Delta Architecture:
First run: Full write of all users
Subsequent runs: 99% write reduction by only storing changes
3 Cosmos containers: users_raw (current state), user_changes (audit trail with 365d TTL), snapshots (metadata)
Infrastructure (Bicep):
Serverless Function App (PowerShell 7.4)
Managed Identity for authentication (no stored credentials)
RBAC permissions to Graph API, Storage, Cosmos DB, and AI Foundry
7-day blob lifecycle for pilot
The diagram is now in the plan file. What would you like me to help you with next? Are you looking to: