#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/KevinBaptiste/windows-washing/main/win.bat -o /opt/docker/apache/files/run-win-cleaning.bat
echo "$(date) - win.bat mis à jour" >> /var/log/webhook-deploy.log