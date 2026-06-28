# Introduction

I work a lot with REST queries to collect data from various APIs. Of course, I can't bring data or code home to provide samples and evidence due to intellectual property rights and non-disclosure agreements.

Luckily, I also play Eve Online and found a practical use for these skills in manufacturing in the game. Market data, combined with blueprint data, can be used to determine what to build, where to buy materials, and where to sell finished products for the highest profit.

**Eve ESI Home:**  
https://developers.eveonline.com/docs/services/esi/overview/

---

## Files

### **./EveOnline/Data**
- **\*.CSV** — Data stored in UTF‑8 encoded CSV files  

### **./EveOnline/Documents**
- **Manual.pdf** — Project documentation and reference material  

### **./EveOnline/Powershell**
These files are useful for non‑technical Windows users. PowerShell is a vital component in Windows and does not require installation. These scripts were written for PowerShell 5.1, which is included with Windows 10 and 11.

- **GetData.ps1** — Examples of unauthenticated REST API calls using parallelization and threading to retrieve data efficiently  
- **OAuth2.ps1** — Example of authenticated REST calls for non‑web applications  

### **./EveOnline/Python**
If you are a macOS or Linux user, PowerShell is not a valid option. Python is commonly installed on these systems, so I manually ported one script (**GetData.py**) and used an AI to port the other (**OAuth2.py**) from the PowerShell version.

- **GetData.py** — Examples of unauthenticated REST API calls using parallelization and threading  
- **OAuth2.py** — Example of authenticated REST calls for non‑web applications  

### **./EveOnline/Models**
- **MarketModel.xlsm** — Excel‑based model with macros and functions for data processing  
- **MarketModel.ods** — OpenOffice version  
