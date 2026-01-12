# Agents
## Azure AI Foundry Deployment Model

The Azure AI Foundry component should not be implemented as an Azure Function App at all. The Foundry agent framework provides superior architecture for natural language data querying compared to custom Function App implementation. Foundry agents support multi-turn conversations with built-in state management, integrate retrieval augmented generation from blob storage containing query documentation and examples, provide function calling capabilities for executing SQL and Gremlin queries, and handle token counting and conversation history management automatically.

Deploying Foundry as an agent rather than custom Function App eliminates substantial implementation complexity. You avoid building conversation state management, token usage tracking, prompt construction logic, query validation frameworks, and result formatting code. The Foundry agent framework provides these capabilities through managed services accessed via Azure AI Studio. The agent consumes your query documentation stored in blob storage through automatic retrieval augmented generation without requiring custom embedding generation or vector search implementation.

The agent deployment model also simplifies authentication and authorization. Foundry agents integrate with Azure Active Directory enabling you to control which users can access the natural language query interface through standard Entra ID group membership. Function App custom authentication implementation requires additional code handling token validation, user identity extraction, and permission enforcement. Foundry provides this functionality through managed integration with Entra ID.

The function calling capability in Foundry agents maps naturally to your SQL and Gremlin query execution pattern. You define functions representing different query types such as query Cosmos container by entity type, execute Gremlin traversal for attack paths, retrieve specific entity by object identifier, and filter relationships by edge type. The agent receives query documentation through retrieval augmented generation showing examples of how to construct queries for different question patterns. When users ask questions, the agent determines which functions to call, constructs appropriate parameters, executes queries, and synthesizes natural language responses from results.

The cost transparency you identified as critical concern becomes easier to implement through Foundry agent deployment. Azure AI Studio provides built-in token usage tracking and cost estimation showing how much each conversation consumes in Azure OpenAI API calls. You can surface this information directly to users through the Foundry interface without building custom metering infrastructure. Organizations understand their spending on natural language querying through native Azure billing integration showing Foundry agent consumption separately from other platform components.

The deployment architecture uses Foundry agent hosted in Azure AI Studio with function calling executing read-only queries against your Cosmos DB containers and Gremlin database. The agent identity holds read-only permissions to data stores with no write access and no Graph API permissions. Users authenticate to the Foundry agent through Entra ID with access controlled through group membership. The agent retrieves query documentation from blob storage through automatic retrieval augmented generation providing examples and schema information for query construction. Function definitions specify available query operations with parameter schemas and return types. The agent generates function calls based on user questions, executes queries through the function calling framework, and synthesizes responses from query results.

This architecture delivers the natural language query capability you envision while minimizing implementation complexity, providing superior conversation management, enabling straightforward cost tracking, and maintaining strong security isolation through read-only permissions and managed authentication.


# Document
**Azure AI Foundry Integration Assessment**

Azure AI Foundry can absolutely serve as the natural language interface for your Entra Risk platform, and the architecture you have described supports this use case effectively. The approach is both technically sound and strategically sensible for an open source security tool.

**Technical Viability**

Your data collection architecture eliminates the primary cost driver that typically plagues AI-powered security tools. Most systems that attempt natural language querying over identity and access management data make expensive real-time API calls for every user question. Your platform collects comprehensively on a schedule, stores efficiently with ninety-nine percent write reduction after initial runs, and maintains all data in queryable Cosmos DB containers. Azure OpenAI would query pre-collected data rather than triggering Graph API calls, making the cost structure predictable and manageable.

The data model you have built is well-suited for AI-assisted querying. Your six Cosmos containers use logical type discriminators, your thirty-three edge types follow consistent naming conventions, and your temporal fields enable point-in-time analysis. The schema is complex enough that natural language abstraction provides genuine value, but structured enough that an LLM with good examples can learn to generate correct queries. Storing comprehensive query documentation and examples in blob storage for retrieval augmented generation is the correct pattern for teaching Azure OpenAI your specific schema.

The function calling capability in Azure OpenAI enables the model to execute SQL queries against your Cosmos containers and Gremlin traversals against your graph database, retrieve results, and synthesize explanations in natural language. This is a proven pattern for structured data interrogation.

**Implementation Sequence and Timing**

Your stated sequence is correct. Complete the Gremlin integration in version three point six before adding the Azure AI Foundry layer. Attack path queries represent the highest value use case for natural language interaction, and those queries require the Gremlin graph database. Without Gremlin, you would limit the AI interface to simple entity lookups and relationship queries in SQL, which undermines the core value proposition. Users asking questions like “show me the attack path from user X to Global Administrator” expect graph traversal capabilities that only Gremlin provides.

The attack path snapshots you generate hourly serve a dual purpose in this architecture. They provide immediate value as pre-computed visualizations, and they also function as high-quality training examples for the AI model. When you document how to query for paths to global admin or dangerous service principals, you can reference the exact Gremlin queries that power your snapshots. This creates a direct mapping between user questions and known-good query patterns.

**Cost Structure and User Economics**

The economic model for an open source tool with Azure OpenAI integration requires transparency rather than subsidy. Your infrastructure costs remain controlled through efficient collection and storage. The variable cost falls on Azure OpenAI inference, which users will pay based on their query volume and conversation length.

GPT-4 class models currently price around three cents per thousand input tokens and six cents per thousand output tokens. A security analyst conducting an investigation might execute dozens of queries with back-and-forth conversation to explore findings. Token consumption accumulates from the user’s questions, the retrieved query documentation for context, the generated queries and their results, and the synthesized explanations. A thorough investigation could easily consume hundreds of thousands of tokens.

You should surface token usage and estimated costs directly in the interface so users understand their spending in real time. Consider implementing conversation management features that allow users to start fresh contexts to avoid dragging full conversation history through every query. Provide clear documentation about expected costs for typical usage patterns.

For an open source security tool, the most practical deployment model involves users bringing their own Azure OpenAI endpoint and API key. This eliminates your need to subsidize inference costs while giving users direct control over their spending. Organizations already using Azure typically have OpenAI capacity deployed, making integration straightforward.

**Quality Control and Hallucination Risk**

Language models can generate plausible but incorrect queries, which poses material risk in security tooling where incorrect results could lead to wrong conclusions about access rights or attack paths. Your mitigation strategy should include several layers of validation.

First, implement query validation before execution. Check generated SQL queries for allowed operations, verify that table and column references match your schema, and confirm that Gremlin traversals use only your defined edge types and vertex labels. Reject queries that attempt operations outside your documented patterns.

Second, provide the model with comprehensive examples covering common query patterns. Your attack path snapshots already demonstrate seven important query types. Expand this example library to cover entity lookups, relationship traversals, historical queries using temporal fields, and aggregations. The more high-quality examples the model sees through retrieval augmented generation, the more likely it generates correct queries.

Third, show generated queries to users before execution when appropriate. For complex attack path questions, display the Gremlin traversal alongside results so security analysts can verify the logic. This builds trust and helps users learn the query language over time.

Fourth, implement result validation by checking for empty results, unreasonably large result sets, or results that contradict known constraints. If a query for privileged role assignments returns zero results, the model should recognize this as suspicious and potentially regenerate the query rather than confidently stating no privileged assignments exist.

**Strategic Assessment**

The natural language interface addresses a real barrier to adoption for security tools. Security analysts understand identity and access concepts but may not know Gremlin syntax or your specific edge type taxonomy. Asking “which service principals have credentials that will expire in the next thirty days” is more accessible than constructing the equivalent query manually. The value proposition is legitimate.

Your open source positioning differentiates this from commercial offerings that charge per-seat or per-query. Organizations can deploy your collection infrastructure, bring their own OpenAI capacity, and gain natural language querying over their Entra environment without vendor lock-in. This model should resonate with security teams that want flexibility and control.

The combination of comprehensive data collection, efficient storage, graph database projection, and AI-assisted querying creates a complete security posture platform. Each layer adds genuine value rather than serving as technology demonstration.

**Recommendation**

Proceed with the Azure AI Foundry integration after completing Gremlin in version three point six. Design the interface for users to provide their own Azure OpenAI endpoint. Invest heavily in query examples and validation logic. Surface costs transparently. Position the natural language capability as an accelerator for security analysts rather than a replacement for understanding the underlying data model.

This is a sound technical approach for a legitimate problem in enterprise security tooling.​​​​​​​​​​​​​​​​