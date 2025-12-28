# OutlineWS
Outline WebSocket + Nginx Setup

1. Make a subdomain, add A and AAAA records
2. Create the
   ```nano script install-outline.sh```
3. Run
  ```chmod +x install-outline.sh```
  ```./install-outline.sh```

4. When running, enter:

- Your domain (e.g., subdomain.example.com)
- Email for SSL


5.  Commands will be available
```
outline-status

outline-addkey "First Device"
outline-addkey "Second Device"

# Show keys
outline-listkeys

# Remove key
outline-removekey outline-config-abc123.txt
```
