Entry Points: HTTP and Timer triggers that start the orchestration
Orchestrator: Central coordinator with partial failure handling
Phase 1 - Data Collection (Parallel):
CollectEntraUsers → Graph API v1.0
CollectEntraGroups → Graph API beta
Both stream to Blob Storage in JSONL format
Staging Layer: Azure Blob Storage as checkpoint/buffer
Phase 2 - Delta Indexing (Parallel with Retry):
IndexInCosmosDB with delta detection
IndexGroupsInCosmosDB with delta detection
Data Persistence: Cosmos DB with 6 containers
Phase 3 - Optional: AI Foundry connectivity test
UI: Dashboard for viewing user and group data
External Integrations: Microsoft Graph API and Azure AI Foundry
Workflow Understanding:
The system follows a modern delta architecture:
Triggers initiate the Orchestrator
Parallel collection streams data to Blob Storage (fast staging)
Parallel indexing with delta detection compares new vs existing data
Only changes (new/modified/deleted) written to Cosmos DB
Dashboard provides web UI for viewing the data


# Diagrams

## High-Level Architecture/Workflow Diagram

```mermaid
flowchart TB
    subgraph Triggers["Entry Points"]
        HTTP[HttpTrigger<br/>Manual POST Request]
        Timer[TimerTrigger<br/>Every 6 Hours CRON]
    end

    subgraph Orchestration["Durable Functions Orchestration"]
        Orch[Orchestrator<br/>Coordinates Workflow<br/>Partial Failure Handling]
    end

    subgraph Collection["Phase 1: Data Collection (Parallel)"]
        CollectUsers[CollectEntraUsers<br/>Graph API v1.0<br/>2-3 minutes]
        CollectGroups[CollectEntraGroups<br/>Graph API beta<br/>1-2 minutes]
    end

    subgraph Storage["Staging Layer"]
        Blob[(Azure Blob Storage<br/>raw-data container<br/>JSONL format)]
    end

    subgraph Indexing["Phase 2: Delta Indexing (Parallel + Retry)"]
        IndexUsers[IndexInCosmosDB<br/>Delta Detection<br/><br/>Max 3 Retries]
        IndexGroups[IndexGroupsInCosmosDB<br/>Delta Detection<br/><br/>Max 3 Retries]
    end

    subgraph Database["Data Persistence"]
        Cosmos[(Cosmos DB<br/>6 Containers:<br/>users_raw, user_changes<br/>groups_raw, group_changes<br/>service_principals_raw, sp_changes<br/>snapshots)]
    end

    subgraph Optional["Phase 3: Optional Features"]
        AI[TestAIFoundry<br/>AI Connectivity Test<br/>Always Success]
    end

    subgraph External["External Services"]
        Graph[Microsoft Graph API<br/>Users, Groups, SPs<br/>Managed Identity Auth]
        AIFoundry[Azure AI Foundry<br/>Optional Integration]
    end

    subgraph UI["User Interface"]
        Dashboard[Dashboard<br/>HTTP GET<br/>Bootstrap UI<br/>Users & Groups Tabs]
    end

    HTTP --> Orch
    Timer --> Orch

    Orch --> CollectUsers
    Orch --> CollectGroups

    CollectUsers --> |Query + Paginate| Graph
    CollectGroups --> |Query + Paginate| Graph

    CollectUsers --> |Stream JSONL| Blob
    CollectGroups --> |Stream JSONL| Blob

    Blob --> IndexUsers
    Blob --> IndexGroups

    IndexUsers --> |Read Existing| Cosmos
    IndexGroups --> |Read Existing| Cosmos

    Cosmos --> |Compare| IndexUsers
    Cosmos --> |Compare| IndexGroups

    IndexUsers --> |Write Changes Only| Cosmos
    IndexGroups --> |Write Changes Only| Cosmos

    Orch --> AI
    AI --> |Test Connection| AIFoundry

    Dashboard --> |Read Data| Cosmos
    Dashboard --> |Fallback Read| Blob

    classDef trigger fill:#e1f5ff,stroke:#01579b,stroke-width:2px
    classDef orchestrator fill:#fff9c4,stroke:#f57f17,stroke-width:3px
    classDef activity fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef storage fill:#e8f5e9,stroke:#1b5e20,stroke-width:2px
    classDef external fill:#fce4ec,stroke:#880e4f,stroke-width:2px
    classDef ui fill:#e0f2f1,stroke:#004d40,stroke-width:2px

    class HTTP,Timer trigger
    class Orch orchestrator
    class CollectUsers,CollectGroups,IndexUsers,IndexGroups,AI activity
    class Blob,Cosmos storage
    class Graph,AIFoundry external
    class Dashboard ui
```

```mermaid
graph TB
    subgraph "Triggers"
        Timer[Timer Trigger<br/>Every 6 hours]
        HTTP[HTTP Trigger<br/>Manual execution]
    end
    
    subgraph "Azure Function App"
        Orch[Orchestrator<br/>Durable Function]
    end
    
    subgraph "Data Collection & Processing"
        Collect[CollectEntraUsers<br/>Activity]
        Index[IndexInCosmosDB<br/>Activity]
        AI[TestAIFoundry<br/>Activity]
    end
    
    subgraph "Data Sources"
        Entra[Microsoft Entra ID<br/>Graph API]
    end
    
    subgraph "Data Storage"
        Blob[Azure Blob Storage<br/>raw-data container<br/>JSONL format]
        Cosmos[Cosmos DB<br/>EntraData database]
    end
    
    subgraph "Data Access"
        Dashboard[Dashboard<br/>HTTP Endpoint]
        Diag[DiagnosticTest<br/>HTTP Endpoint]
    end
    
    Timer -->|Start| Orch
    HTTP -->|Start| Orch
    
    Orch -->|1. Collect| Collect
    Orch -->|2. Index| Index
    Orch -->|3. Test| AI
    
    Collect -->|Query Users| Entra
    Collect -->|Stream JSONL| Blob
    
    Index -->|Read JSONL| Blob
    Index -->|Delta Detection| Cosmos
    Index -->|Write Changes| Cosmos
    
    Dashboard -->|Read Data| Cosmos
    Dashboard -.->|Fallback| Blob
    
    Diag -->|Verify Access| Blob
    
    AI -.->|Optional Test| Cosmos
    
    style Orch fill:#0078d4,color:#fff
    style Collect fill:#107c10,color:#fff
    style Index fill:#107c10,color:#fff
    style AI fill:#ff8c00,color:#fff
    style Dashboard fill:#5c2d91,color:#fff
```

—————

```mermaid
sequenceDiagram
    participant T as Timer/HTTP Trigger
    participant O as Orchestrator
    participant C as CollectEntraUsers
    participant G as Graph API
    participant B as Blob Storage
    participant I as IndexInCosmosDB
    participant DB as Cosmos DB
    participant A as TestAIFoundry
    participant AI as AI Foundry

    T->>O: Start Orchestration
    activate O
    Note over O: Generate timestamp<br/>yyyy-MM-ddTHH-mm-ssZ
    
    O->>C: Step 1: Collect Users
    activate C
    C->>G: Query users with pagination<br/>$select fields, $top=999
    G-->>C: Return user batches
    C->>B: Stream to append blob<br/>timestamp/users.jsonl
    C-->>O: Success + UserCount + BlobName
    deactivate C
    
    Note over O: If collection fails: STOP<br/>If succeeds: Continue
    
    O->>I: Step 2: Index with Delta Detection
    activate I
    I->>B: Read JSONL from blob
    B-->>I: User data
    I->>DB: Read existing users (input binding)
    DB-->>I: Existing user state
    Note over I: Delta Detection:<br/>- Compare fields<br/>- Identify New/Modified/Deleted<br/>- Generate change log
    I->>DB: Write to 3 containers:<br/>1. users_raw (changes only)<br/>2. user_changes (log)<br/>3. snapshots (summary)
    I-->>O: Success + Delta Stats
    deactivate I
    
    Note over O: If indexing fails: RETRY 3x<br/>Data safe in blob
    
    O->>A: Step 3: Test AI Foundry (Optional)
    activate A
    A->>AI: Test connectivity<br/>Send data summary
    AI-->>A: AI Response
    A-->>O: Success (always true)
    deactivate A
    
    O-->>T: Final Result with Stats
    deactivate O
```