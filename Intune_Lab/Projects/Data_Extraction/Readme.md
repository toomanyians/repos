# Introduction

Reporting for just one tenant in Azure is relatively simple. Seperation of environments and SDLC (Dev, UAT, Prod) mean that most corporations have three tenants. Adding the size of the environment and reporting requirements adds more complexity.  
Often it makes sense to collect all the data from all three tenants, and this requires some central storage for transformation of data for processing efficiency and historical data maintenance.  
For large infrastructures with prohibitive retention policies, Sharepoint is not an option, but it can be for smaller, less regulated environments.  
I will be using a PostGres server as a Data Warehouse to serve up dashboards in Power BI and Excel reports in SharePoint.

Stay tuned.... This is my next focus using Sharepoint (Lists and CSV) or PostGres... If I get really ambitious, I might add MSSQL...

---

## Files

### **./Powershell/**
- **\*.\*** — Code examples for EntraID and Intune using Graph API, Graph API reports and Log Analytics. (In progress)

### **./Python/**
- **\*.\*** — Code examples for EntraID and Intune using Graph API, Graph API reports and Log Analytics. (In progress)
