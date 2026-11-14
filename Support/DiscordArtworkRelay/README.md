# Local album artwork on Discord

iSyncer first searches its catalogs by Album Artist, then by Artist. If neither search finds a cover and you enabled **Share artwork from my music files**, iSyncer sends a JPEG thumbnail of the player cover to the hosted iSyncer relay. Anyone with the unlisted URL can fetch it for five minutes. iSyncer renews the URL for long tracks. The hosted Worker source lives in `Hosted/`.

## Run your own relay

1. On a host with a public DNS name, run `python3 relay.py` with `ISYNCER_RELAY_URL` set to its public HTTPS origin (for example, `https://art.example.com`) and `ISYNCER_RELAY_TOKEN` set to a random secret of at least 32 characters. Keep the secret in your service environment.
2. Configure an HTTPS reverse proxy for that hostname. For Caddy, use this site definition:

   ```caddyfile
   art.example.com {
       reverse_proxy 127.0.0.1:8788
   }
   ```

   The Python process listens on loopback. The proxy makes the JPEG URLs available to Discord. Anyone with a live cover URL can request that thumbnail until it expires. Keep access logging disabled for paths that contain cover tokens.
3. In **iSyncer → Settings → Discord**, enable **Show album artwork for music** and **Share artwork from my music files**. Open **Advanced**, enter the public origin and the token, then click **Save Relay Token**. Clear the custom URL to switch back to the hosted relay.
