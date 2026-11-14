# Hosted Discord artwork relay

This Cloudflare Worker serves short-lived artwork thumbnails. The macOS app requests a signed upload challenge, completes a small proof of work, then uploads the JPEG. Discord can fetch the unlisted image over HTTPS. The Worker limits accepted uploads per client and in total, and each URL expires after five minutes.

Run `npm run build` to produce `dist/server/index.js`. Apply the SQL migration under `drizzle/` and bind the D1 database as `DB`. Set `RELAY_ORIGIN` to the public HTTPS origin and set `RELAY_SIGNING_KEY` as a private random secret. Check `GET /health` after deployment. In ChatGPT Sites, use `.openai/hosting.example.json` as the basis for the project’s local hosting manifest.

The macOS app reads the default relay origin from `Resources/Info.plist`. Custom self-hosted relays use the separate Python implementation described in the [parent directory](../README.md).
