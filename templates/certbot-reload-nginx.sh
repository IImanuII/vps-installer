#!/bin/sh
# Ricarica Nginx dopo ogni rinnovo dei certificati.
nginx -t && systemctl reload nginx
