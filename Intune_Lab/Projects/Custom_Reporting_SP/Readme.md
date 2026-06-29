# Introduction

Four years ago, I got introduced to Intune. I was not impressed, it couldn't even report the start mode and status of a Windows service.
It was clear it needed to be extended and having experience with Configuration Manager Compiance Baselines, I quickly embraced Custom Compliance Scripts with Remediation.
The API for submitting JSON data to Log Analytics is changing and now requires authentication to a Service Principal.
Instead of using a Client Secret, I wanted to use a Client Certificate, but very few examples for this are available.
Here is how I would do it.

---

## Files

- **Secure Custom Inventory.pdf** — Step by step instructions for obtaining a test certificate, Service Principal, Data Collection Endpoint, Log Analytics Table and Data Collection Rule configuration.
- **Get-Cert.ps1** — Powershell script to generate and export a self-signed certificate Public and Private keys.
- **Custom_Inventory.ps1** — Windows Custom Compliance sccript using a Client Certificate to authenticate as a Service Principal.
- **Output.json** — Used to configure the Log Analytics table and DCR. Sample data submission in JSON format.
- **Inventory.log** — Sample log output of Custom_Inventory.ps1


