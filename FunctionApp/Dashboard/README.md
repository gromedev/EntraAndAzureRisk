# Dashboard Function

## Overview

The Dashboard function provides a web-based, human-friendly interface for viewing Entra user data and change history. It displays real-time data from Cosmos DB with interactive sorting, filtering, and pagination features.

## Features

- **Summary Statistics**: Total users, new users, modified users, and deleted users
- **User List**: Sortable, filterable table showing current user data
- **Recent Changes**: Last 100 changes with expandable field-level deltas
- **Interactive Features**:
  - Click column headers to sort
  - Search/filter across all fields
  - Client-side pagination (25/50/100 rows per page)
  - Expandable change details showing before/after values
- **Mobile-Responsive**: Works on all device sizes
- **Secure**: Requires function key for access

## Authentication

This function uses **function-level authentication**. You must provide a valid function key to access the dashboard.

## Accessing the Dashboard

### Azure Deployment

1. **Deploy the Function App**:
   ```bash
   cd /Users/thomas/git/GitHub/EntraAndAzureRisk/FunctionApp
   func azure functionapp publish <your-function-app-name>
   ```

2. **Get the Function Key**:
   ```bash
   func azure functionapp list-functions <your-function-app-name> --show-keys
   ```

   Or from Azure Portal:
   - Navigate to your Function App
   - Go to Functions → Dashboard → Function Keys
   - Copy the `default` key

3. **Access the Dashboard**:
   ```
   https://<your-function-app-name>.azurewebsites.net/api/dashboard?code=<function-key>
   ```

## Data Sources

The dashboard queries three Cosmos DB containers:

1. **snapshots**: Collection metadata (latest snapshot)
   - Total users, new/modified/deleted counts
   - Collection timestamp

2. **users_raw**: Current user data (top 500 most recently modified)
   - User Principal Name
   - Display Name
   - User Type
   - Account Status (Enabled/Disabled)
   - Last Sign-In Date
   - External User State

3. **user_changes**: Recent changes (last 100)
   - Change Type (new/modified/deleted)
   - Change Timestamp
   - Field-level deltas (before/after values)

## Environment Variables Required

The following environment variables must be configured (already set in Azure via Bicep):

- `COSMOS_DB_ENDPOINT`: Cosmos DB account endpoint
- `COSMOS_DB_DATABASE`: Database name (EntraData)
- Managed Identity must have Cosmos DB Built-in Data Contributor role

## Performance

- **Load Time**: 2-4 seconds for 500 users + 100 changes
- **Data Size**: ~250KB compressed
- **Client-Side Operations**: Instant sorting, filtering, pagination

## Security

- **Authentication**: Function key required (via `?code=` parameter)
- **Authorization**: Managed Identity with RBAC on Cosmos DB
- **HTTPS**: Enforced by Function App configuration
- **XSS Prevention**: All user data is escaped using `textContent`
- **No Write Operations**: Dashboard is read-only

## Troubleshooting

### Error: "Dashboard error: Cosmos DB configuration missing"

**Solution**: Ensure `COSMOS_DB_ENDPOINT` and `COSMOS_DB_DATABASE` environment variables are set in your Function App configuration.

### Error: "Unable to load dashboard data"

**Possible causes**:
1. Managed Identity not configured
2. Managed Identity missing Cosmos DB RBAC role
3. Cosmos DB endpoint/database incorrect
4. Network connectivity issues

**Check**:
- Function App → Identity → System assigned is enabled
- Cosmos DB → Access Control (IAM) → Role assignments includes Function App with "Cosmos DB Built-in Data Contributor" role

### No data showing

**Possible causes**:
1. No data collection has run yet
2. Cosmos DB containers are empty

**Solution**: Run the data collection manually via HTTP trigger or wait for timer trigger.

## Future Enhancements

- Export to CSV/Excel
- Date range filters for changes
- Charts and graphs (user growth, change frequency)
- Azure AD authentication (replace function key)
- Real-time updates via SignalR
- User detail drill-down pages

## Technical Details

- **Runtime**: PowerShell 7.4
- **Framework**: Azure Functions (HTTP Trigger)
- **UI**: Bootstrap 5.3, Vanilla JavaScript
- **Data Access**: `EntraDataCollection` module via Managed Identity
