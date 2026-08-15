# getassay.dev

Source for [getassay.dev](https://getassay.dev), the landing page and installer for the Assay CLI.

## Deployment

Hosted on **Cloudflare Pages**.

1.  Connect this repo to Cloudflare Pages.
2.  Set **Build output directory** to `/` (Project Root).
3.  Deploy.

## Installer provenance

`install.sh` is copied from the immutable Assay source commit recorded in
`install.provenance.json`. Pull requests and pushes to `main` run:

```bash
bash scripts/test-installer-provenance-contract.sh
bash scripts/check-installer-provenance.sh
```

The first command exercises the fail-closed and offline boundary without using
the network. The second checks the committed installer and, when reachable, the
immutable source. These checks do **not** prove that the currently deployed
`https://getassay.dev/install.sh` matches the repository; live drift remains a
separate operational measurement.

## Files

-   `index.html`: The landing page.
-   `install.sh`: The installer script (served at /install.sh).
-   `_headers`: Security headers config.
