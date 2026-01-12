# Performance Scaling Estimates

**Date:** 2026-01-12
**Baseline Tenant:** Development environment

---

## Current Baseline Metrics

### Entity Counts

| Entity Type | Count |
|-------------|-------|
| Users | 70 |
| Groups | 52 |
| Service Principals | 323 |
| Devices | 2 |
| Admin Units | 1 |
| Applications | 17 |
| **Total Principals** | 448 |
| **Total Edges** | 745 |
| **Total Policies** | 303 |

### Blob Storage (per collection run)

| File | Size |
|------|------|
| principals.jsonl | 1.3 MB |
| edges.jsonl | 580 KB |
| policies.jsonl | 1.8 MB |
| resources.jsonl | 57 KB |
| events.jsonl | 341 KB |
| **Total** | ~4.1 MB |

### Performance

| Metric | Value |
|--------|-------|
| Orchestration time | ~13 min |
| Dashboard load time | 4.5 sec |
| Dashboard payload size | 4.3 MB |

---

## Scaled Estimates

### Entity Counts at Scale

| Entity | Current | 10x | 100x | 150x |
|--------|---------|-----|------|------|
| Users | 70 | 700 | 7,000 | 10,500 |
| Groups | 52 | 520 | 5,200 | 7,800 |
| Service Principals | 323 | 3,230 | 32,300 | 48,450 |
| Devices | 2 | 20 | 200 | 300 |
| Applications | 17 | 170 | 1,700 | 2,550 |
| **Total Principals** | 448 | 4,480 | 44,800 | 67,200 |
| **Edges** | 745 | 7,450 | 74,500 | 111,750 |
| **Policies** | 303 | 3,030 | 30,300 | 45,450 |

### Blob Storage at Scale

| File | Current | 10x | 100x | 150x |
|------|---------|-----|------|------|
| principals.jsonl | 1.3 MB | 13 MB | 130 MB | 195 MB |
| edges.jsonl | 580 KB | 5.8 MB | 58 MB | 87 MB |
| policies.jsonl | 1.8 MB | 18 MB | 180 MB | 270 MB |
| resources.jsonl | 57 KB | 570 KB | 5.7 MB | 8.5 MB |
| events.jsonl | 341 KB | 3.4 MB | 34 MB | 51 MB |
| **Total per run** | ~4 MB | ~40 MB | ~400 MB | ~600 MB |

### Performance at Scale

| Metric | Current | 10x | 100x | 150x |
|--------|---------|-----|------|------|
| Orchestration time | 13 min | 30-45 min | 3-5 hrs | 5-8 hrs |
| Dashboard load | 4.5 sec | 15-30 sec | **Timeout** | **Timeout** |
| Dashboard size | 4.3 MB | 43 MB | 430 MB | 645 MB |

---

## Key Bottlenecks

### 1. Graph API Throttling

- **Limit:** ~10,000 requests per 10 minutes
- **Impact:** 100x+ tenants will hit throttling limits
- **Current mitigation:** $batch API implemented (20 requests per batch)

### 2. Dashboard Browser Limits

- **Problem:** Browsers struggle with 50+ MB payloads
- **Impact:** 100x+ tenants will timeout or crash browser
- **Threshold:** ~50 MB practical limit for single-page load

### 3. Cosmos DB RU/s

- **Current:** 400 RU/s (default)
- **Required at 10x:** 1,000-2,000 RU/s
- **Required at 100x:** 4,000-10,000 RU/s
- **Required at 150x:** 10,000-20,000 RU/s

### 4. Azure Functions Memory

- **Default:** 1.5 GB (Consumption plan)
- **Risk:** Large JSON arrays may cause OOM
- **Current mitigation:** Streaming JSONL writes

### 5. Orchestration Duration

- **Problem:** 5-8 hour runs exceed 6-hour collection cycles
- **Impact:** Data staleness, overlapping runs

---

## Mitigation Strategies

### Priority 1: Enable Cosmos Autoscale (Config change)

```bicep
resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  properties: {
    resource: { ... }
    options: {
      autoscaleSettings: {
        maxThroughput: 4000  // Scales 400-4000 RU/s automatically
      }
    }
  }
}
```

**Impact:** Handles RU spikes automatically
**Effort:** Low (Bicep update)

### Priority 2: Parallelize Collectors (Code change)

Current orchestrator runs collectors sequentially. Parallelize independent collectors:

```powershell
# Fan-out: Run collectors in parallel
$collectorTasks = @(
    Start-DurableTask -FunctionName 'CollectUsers' -Input $context
    Start-DurableTask -FunctionName 'CollectEntraGroups' -Input $context
    Start-DurableTask -FunctionName 'CollectEntraServicePrincipals' -Input $context
    Start-DurableTask -FunctionName 'CollectDevices' -Input $context
)

# Fan-in: Wait for all to complete
$results = Wait-DurableTask -Task $collectorTasks
```

**Impact:** 2-3x faster orchestration
**Effort:** Medium

### Priority 3: Delta Query API (Architecture change)

Only fetch changes since last sync instead of full collection.

**Impact:** 90%+ reduction in API calls after initial sync
**Effort:** Medium
**Reference:** `/docs/Epic 0-plan-delta-Architecture.md`

### Priority 4: Dashboard Pagination (Rewrite)

For 100x+ tenants, dashboard needs:
- Server-side pagination (100 items per page)
- Lazy-load tabs (only fetch active tab data)
- Search/filter API endpoints
- Summary view as default

**Impact:** Required for enterprise scale
**Effort:** High (significant rewrite)

---

## Cost Estimates

### Storage Costs (Azure Blob)

| Scale | Monthly Storage | Monthly Cost (est) |
|-------|-----------------|-------------------|
| Current | ~120 MB/month | < $0.01 |
| 10x | ~1.2 GB/month | ~$0.02 |
| 100x | ~12 GB/month | ~$0.25 |
| 150x | ~18 GB/month | ~$0.40 |

*Based on 4 collection runs per day, 30 days*

### Cosmos DB Costs

| Scale | RU/s Needed | Monthly Cost (est) |
|-------|-------------|-------------------|
| Current | 400 | ~$24 |
| 10x | 1,000-2,000 | ~$60-120 |
| 100x | 4,000-10,000 | ~$240-600 |
| 150x | 10,000-20,000 | ~$600-1,200 |

*Autoscale recommended for variable workloads*

### Function App Costs

| Scale | Plan Recommendation | Monthly Cost (est) |
|-------|--------------------|--------------------|
| Current | Consumption | ~$0-5 |
| 10x | Consumption | ~$5-20 |
| 100x | Premium EP1 | ~$150 |
| 150x | Premium EP2 | ~$300 |

---

## Recommendations by Tenant Size

### Small (Current - 500 users)
- Current architecture is sufficient
- No changes needed

### Medium (500 - 5,000 users) - 10x
- Enable Cosmos autoscale
- Consider parallel collectors
- Dashboard still functional

### Large (5,000 - 50,000 users) - 100x
- **Required:** Delta Query API
- **Required:** Dashboard pagination or separate Alpenglow dashboard
- Premium Function App plan
- Cosmos autoscale to 10,000 RU/s

### Enterprise (50,000+ users) - 150x
- All Large recommendations plus:
- Dedicated Cosmos container per entity type
- Consider Azure Data Explorer for analytics
- CDN for dashboard static assets
- Background processing with Azure Service Bus

---

## Next Steps

1. [ ] Enable Cosmos autoscale in Bicep templates
2. [ ] Implement parallel collectors in Orchestrator
3. [ ] Complete Delta Query API implementation (Task #17)
4. [ ] Design Alpenglow dashboard with pagination
5. [ ] Load test with synthetic 10x dataset
