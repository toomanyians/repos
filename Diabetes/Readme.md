# Introduction

In January 2025, my male cat was diagnosed with Diabetes.

It has proven quite difficult to control, and so I decided to monitor him with a FreeStyle Libre sensor which provides almost real-time monitoring data to an app on my phone. The alarms have been most useful to alert me when his blood glucose levels go low at night while I am asleep.

The monitoring data can be downloaded from the LibreView web app, providing me a data source I could use to learn Power BI at home.

---

## Files

### **./Diabetes/Data**
- **MewBaxter_glucose.zip** — UTF‑8 encoded CSV file containing the latest snapshot of data  
- **MewBaxter_glucose_2026-03-13.zip** — LibreView only retains data for 18 months; this is the first year's archive  

### **./Diabetes/Documents**
- **Mew and Diabetes.pdf** — Documentation summarizing everything you need to know about cat diabetes and how to install and use the Power BI dashboard, including customization if you want to use it for your own cat  

### **./Diabetes/Power BI**
- **Mew Glucose.pbix** — The dashboard  
  - Transforms are done in M‑Language to smooth the data  
  - DAX is used for dimensioning (data normalization, lookup tables), etc.  
